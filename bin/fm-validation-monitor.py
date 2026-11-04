"""Read-only validation monitor implementation; shell entry point owns usage."""

import csv
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from contextlib import closing
from pathlib import Path

BIN = Path(__file__).resolve().parent
BRIDGE = BIN / "fm-validation-monitor.sh"
HOME = Path(os.environ["FM_HOME"]).resolve()
STATE = Path(os.environ.get("FM_STATE_OVERRIDE", HOME / "state"))
DATA = Path(os.environ.get("FM_DATA_OVERRIDE", HOME / "data"))
CONFIG = Path(os.environ.get("FM_CONFIG_OVERRIDE", HOME / "config"))
PROJECTS = Path(os.environ.get("FM_PROJECTS_OVERRIDE", HOME / "projects"))
RECORD = STATE / "validation-monitor.json"
CHECK_ID = "validation-monitor"
DEFAULTS = {
    "parked_secs": 1800,
    "step_secs": 3600,
    "step_thresholds": {"push": 600, "pr": 600, "lint": 900, "ci": 7200},
    "slot_cap": 2,
    "swap_mb": 1024,
    "repos": [],
}
IDENT = re.compile(r"[A-Za-z0-9_-]+")


def read_text(path):
    try:
        return path.read_text()
    except OSError:
        return ""


def safe_file(path):
    return not path.is_symlink() and (
        not path.exists() or (path.is_file() and path.stat().st_nlink == 1)
    )


def atomic_write(path, body, mode=0o600):
    if not safe_file(path):
        raise ValueError("unsafe monitor record")
    fd, name = tempfile.mkstemp(prefix=".validation-monitor-", dir=STATE)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as stream:
            stream.write(body)
        if not safe_file(path):
            raise ValueError("unsafe monitor record")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Reader:
    def __init__(self):
        # Leave room for printing and saving before either standing-check
        # runner's outer bound. Both runners default to thirty seconds.
        outer = os.environ.get("FM_CHECK_TIMEOUT", "30")
        outer = int(outer) if outer.isdigit() else 30
        self.deadline = time.monotonic() + max(0, outer - 5)
        self.primaries = {}

    def run(self, args, cwd=None, body=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            with subprocess.Popen(
                [str(arg) for arg in args],
                cwd=cwd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                start_new_session=True,
            ) as proc:
                try:
                    out, _ = proc.communicate(body, timeout=min(6, remaining))
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate()
                    return None
                return out if proc.returncode == 0 else None
        except (OSError, UnicodeError):
            return None

    def bridge(self, *args, body=None):
        return self.run(["bash", BRIDGE, *args], body=body)

    def primary(self, repo):
        if repo in self.primaries:
            return self.primaries[repo]
        if not repo.is_absolute() or not repo.is_dir():
            return None
        # The first entry is Git's primary copy. Even an explicitly configured
        # gate path that points into a worker copy is normalized before any
        # no-mistakes invocation, never used as the CLI working directory.
        out = self.run(["git", "-C", repo, "worktree", "list", "--porcelain"])
        if out and out.startswith("worktree "):
            primary = Path(out.splitlines()[0][9:])
            if primary.is_dir():
                self.primaries[repo] = primary.resolve()
                return self.primaries[repo]
        return None


def scalar(text, name):
    match = re.search(
        r"^[ \t]*" + re.escape(name) + r":[ \t]*(.*?)[ \t]*$", text, re.MULTILINE
    )
    if not match:
        return ""
    value = match[1]
    if value.startswith('"'):
        try:
            return json.loads(value)
        except ValueError:
            return ""
    return value


def table(text, name):
    lines = text.splitlines()
    for pos, line in enumerate(lines):
        match = re.fullmatch(
            r"(\s*)" + re.escape(name) + r"\[(\d+)\]\{([^}]+)\}:", line
        )
        if not match:
            continue
        columns = match[3].split(",")
        rows = []
        for line in lines[pos + 1 : pos + 1 + int(match[2])]:
            if len(line) - len(line.lstrip()) <= len(match[1]):
                return None
            try:
                cells = next(csv.reader([line.strip()], skipinitialspace=True))
            except (csv.Error, StopIteration):
                return None
            if len(cells) != len(columns):
                return None
            rows.append(dict(zip(columns, cells)))
        return rows if len(rows) == int(match[2]) else None
    return None


def duration(value):
    value = value.removeprefix("parked ").strip()
    parts = re.findall(r"(\d+(?:\.\d+)?)(ms|[dhms])", value)
    if not parts or "".join(n + unit for n, unit in parts) != value:
        return 0
    return int(
        sum(
            float(n) * {"d": 86400, "h": 3600, "m": 60, "s": 1, "ms": 0.001}[unit]
            for n, unit in parts
        )
    )


def config():
    result = dict(DEFAULTS)
    text = read_text(CONFIG / "validation-monitor.json")
    supplied = json.loads(text) if text.strip() else {}
    if not isinstance(supplied, dict) or supplied.keys() - DEFAULTS.keys():
        raise ValueError("invalid validation monitor configuration")
    result.update(supplied)
    for key in ("parked_secs", "step_secs", "slot_cap", "swap_mb"):
        if type(result[key]) is not int or not 1 <= result[key] <= 31_536_000:
            raise ValueError("invalid validation monitor threshold: " + key)
    thresholds = result["step_thresholds"]
    if not isinstance(thresholds, dict) or any(
        not re.fullmatch(r"[a-z_-]+", step)
        or type(secs) is not int
        or not 1 <= secs <= 31_536_000
        for step, secs in thresholds.items()
    ):
        raise ValueError("invalid validation monitor step thresholds")
    result["step_thresholds"] = {**DEFAULTS["step_thresholds"], **thresholds}
    if not isinstance(result["repos"], list) or any(
        not isinstance(repo, str) or not repo.startswith("/") or "\n" in repo
        for repo in result["repos"]
    ):
        raise ValueError("invalid validation monitor gate repositories")
    return result


def inventory(reader, repo, overview):
    rows = table(overview, "runs")
    count = re.fullmatch(r"(\d+) of (\d+) total", scalar(overview, "count"))
    complete = bool(
        rows is not None and count and len(rows) == int(count[1]) == int(count[2])
    )
    if complete:
        return rows, True
    # The overview caps history. Reuse the same exact CLI-reported repository
    # and read-only database addressing as fm_nm_select_run, but retain ALL
    # active runs, including older ones hidden behind newer branch history.
    dbpath = reader.bridge("--database", repo)
    reported_repo = scalar(overview, "repo")
    if dbpath and reported_repo.startswith("/"):
        try:
            uri = Path(dbpath.strip()).resolve().as_uri() + "?mode=ro"
            with closing(sqlite3.connect(uri, uri=True, timeout=0.1)) as db:
                db.set_progress_handler(
                    lambda: int(time.monotonic() >= reader.deadline), 1000
                )
                db.execute("BEGIN")
                repos = db.execute(
                    "SELECT id FROM repos WHERE working_path = ?", (reported_repo,)
                ).fetchall()
                if len(repos) == 1:
                    records = db.execute(
                        "SELECT id, branch, status, head_sha FROM runs WHERE repo_id = ? "
                        "ORDER BY created_at DESC, id DESC",
                        (repos[0][0],),
                    ).fetchall()
                    return [
                        dict(zip(("id", "branch", "status", "head"), row))
                        for row in records
                    ], True
        except (OSError, ValueError, sqlite3.Error):
            pass
    return rows or [], False


def task_records():
    result = []
    for path in sorted(STATE.glob("*.meta")):
        if path.is_symlink() or not IDENT.fullmatch(path.stem):
            continue
        fields = dict(
            line.split("=", 1) for line in read_text(path).splitlines() if "=" in line
        )
        if fields.get("kind") in ("secondmate", "orphan") or fields.get("remote_host"):
            continue
        result.append((path, fields))
    return result


def repos_to_read(reader, cfg, tasks):
    candidates = [Path(path) for path in cfg["repos"]]
    for line in read_text(DATA / "projects.md").splitlines():
        match = re.match(r"^- (.+?)(?: \[| - )", line)
        if match:
            name = match[1]
            if name not in (".", "..") and "/" not in name:
                candidates.append(PROJECTS / name)
    # Known gates remain discoverable while a task is live, even if the project
    # registry is being repaired. Only recorded project paths are used.
    candidates.extend(
        Path(fields["project"]) for _, fields in tasks if fields.get("project")
    )
    result = set()
    for candidate in candidates:
        primary = reader.primary(candidate)
        if primary:
            result.add(primary)
    return sorted(result)


def queued_count(reader):
    out = reader.run(
        [
            "bash",
            BIN / "fm-tasks-axi.sh",
            "list",
            "--state",
            "queued",
            "--limit",
            "1000",
        ]
    )
    if out is not None:
        rows = table(out, "tasks")
        if rows is not None:
            return len(rows)
    # Manual homes have no structured backend read; count only the queued
    # section, not Done, held, or in-flight work.
    manual = read_text(CONFIG / "backlog-backend").strip() == "manual"
    if not manual:
        return None
    section = ""
    count = 0
    for line in read_text(DATA / "backlog.md").splitlines():
        if line.startswith("## "):
            section = line[3:].strip().lower()
        elif section == "queued" and line.startswith("- "):
            count += 1
    return count


def pressure(reader, cfg):
    load = "unknown"
    try:
        load1 = os.getloadavg()[0]
        cores = os.cpu_count() or 1
        load = f"{load1:.1f}/{cores} cores" + (" high" if load1 >= cores else "")
    except OSError:
        pass
    swap = None
    if sys.platform == "darwin":
        out = reader.run(["sysctl", "-n", "vm.swapusage"])
        match = re.search(r"used = ([0-9.]+)M", out or "")
        if match:
            swap = float(match[1])
    else:
        mem = read_text(Path("/proc/meminfo"))
        total = re.search(r"^SwapTotal:\s+(\d+)", mem, re.MULTILINE)
        free = re.search(r"^SwapFree:\s+(\d+)", mem, re.MULTILINE)
        if total and free:
            swap = (int(total[1]) - int(free[1])) / 1024
    swap_text = (
        "unknown"
        if swap is None
        else f"{swap:.0f}MB" + (" high" if swap >= cfg["swap_mb"] else "")
    )
    return f"load {load}, swap {swap_text}"


def inspect_run(reader, repo, row, previous, tasks, now, cfg):
    run_id = row.get("id", "")
    if not isinstance(run_id, str) or not IDENT.fullmatch(run_id):
        return None
    detail = reader.bridge("--read", repo, "axi", "status", "--run", run_id)
    if (
        not detail
        or scalar(detail, "id") != run_id
        or scalar(detail, "branch") != row.get("branch")
        or not scalar(detail, "status")
    ):
        return None
    facts = (reader.bridge("--facts", body=detail) or "").split()
    if len(facts) != 2:
        return None
    active, parked = (item == "1" for item in facts)
    steps = table(detail, "steps") or []
    actives = table(detail, "active_steps") or []
    gate = scalar(detail, "gate")
    gate = (
        gate
        if gate
        else next(
            (
                step["step"]
                for step in steps
                if step.get("status")
                in ("awaiting_approval", "fix_review", "awaiting_agent")
            ),
            "",
        )
    )
    current = actives or [
        step
        for step in steps
        if step.get("status")
        in (
            "failed",
            "running",
            "fixing",
            "awaiting_approval",
            "awaiting_agent",
            "fix_review",
        )
    ]
    signature = json.dumps(
        [
            scalar(detail, "status"),
            gate,
            [
                (step.get("step"), step.get("status"), step.get("round"))
                for step in current
            ],
        ]
    )
    since = (
        previous.get("since", now) if previous.get("signature") == signature else now
    )
    worker = "gone"
    owner = None
    branch = scalar(detail, "branch")
    matching_tasks = []
    for path, fields in tasks:
        if (
            fields.get("branch") != branch
            or not fields.get("project")
            or not fields.get("worktree")
        ):
            continue
        if reader.primary(Path(fields["project"])) != repo:
            continue
        matching_tasks.append((path, fields))
        # Strict shared head/custody attribution for parked and terminal runs;
        # the library's executing-run exemption is deliberately reused.
        if (
            reader.bridge("--bind", fields["worktree"], body=detail) or ""
        ).strip() != "bound":
            continue
        owner = [path.stem, fields.get("spawn_gen", "")]
        worker = (reader.bridge("--worker", path) or "unknown").strip()
        break
    # A same-branch but unverifiable worker is not proven gone. Nor may an
    # outage while probing a known worker become idle evidence.
    if owner is None and matching_tasks:
        worker = "unknown"
    old_owner = previous.get("owner")
    retired_owner = old_owner and (
        not (STATE / (old_owner[0] + ".meta")).exists()
        or any(
            path.stem == old_owner[0]
            and fields.get("spawn_gen")
            and old_owner[1]
            and fields["spawn_gen"] != old_owner[1]
            for path, fields in tasks
        )
    )
    if retired_owner:
        worker = "gone"
    state = {
        "signature": signature,
        "since": since,
        "owner": old_owner or owner,
        "reported": [],
    }
    conditions = {}
    abort = f"no-mistakes axi abort --run {run_id}"
    prefix = f"validation {run_id} ({repo.name}, {branch})"

    def finding(key, reason):
        conditions[key] = f"{prefix}: {reason}; operator: {abort}"

    unattended = worker in ("gone", "idle")
    if active and parked and unattended:
        age = max(now - since, duration(scalar(detail, "awaiting_agent")))
        if age >= cfg["parked_secs"]:
            finding(
                "parked:" + gate,
                f"parked at {gate or 'approval'} for {age}s; worker {worker}",
            )
    if active:
        pr = scalar(detail, "pr")
        # Query only a URL reported by this exact run. API errors and unknown
        # forge formats preserve prior orphan evidence, never imply closure.
        if re.fullmatch(
            r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*", pr
        ):
            out = reader.run(["gh-axi", "pr", "view", pr], cwd=repo)
            pr_state = scalar(out or "", "state").lower()
            if pr_state in ("merged", "closed"):
                finding(
                    "orphan:pr:" + pr_state, f"orphan run, PR already {pr_state}: {pr}"
                )
            elif pr_state != "open":
                for key in previous.get("reported", []):
                    if key.startswith("orphan:pr:"):
                        conditions[key] = ""
        if retired_owner:
            finding("orphan:task", "orphan run, its recorded task has been torn down")
        if not parked:
            for step in current:
                name = step.get("step", "unknown")
                if step.get("status") not in ("running", "fixing"):
                    continue
                age = max(now - since, duration(step.get("active_for", "")))
                if age >= cfg["step_thresholds"].get(name, cfg["step_secs"]):
                    finding(
                        "slow:" + name + ":" + step.get("round", ""),
                        f"{name} active for {age}s, longer than its configured limit",
                    )
    failed = (
        scalar(detail, "outcome") == "failed" or scalar(detail, "status") == "failed"
    )
    failed_steps = [
        step.get("step", "unknown") for step in steps if step.get("status") == "failed"
    ]
    if unattended and (failed or failed_steps):
        finding(
            "failed:" + ",".join(failed_steps),
            f"failed at {', '.join(failed_steps) or 'unknown step'}; no worker driving it ({worker})",
        )
    if worker == "unknown":
        for key in previous.get("reported", []):
            if key.startswith(("parked:", "failed:")):
                conditions.setdefault(key, "")
    state["reported"] = sorted(conditions)
    new = [
        reason
        for key, reason in conditions.items()
        if reason and key not in previous.get("reported", [])
    ]
    return state, new, active


def check(reader, cfg, old):
    now = int(os.environ.get("FM_VALIDATION_MONITOR_NOW", time.time()))
    tasks = task_records()
    queued = queued_count(reader)
    runs = dict(old.get("runs", {}))
    findings = []
    active_by_gate = {}
    complete_sweep = True
    repos = repos_to_read(reader, cfg, tasks)
    cursor = old.get("repo_cursor", 0) % max(1, len(repos))
    repos = repos[cursor:] + repos[:cursor]
    run_cursors = dict(old.get("run_cursors", {}))
    for repo in repos:
        overview = reader.bridge("--read", repo, "axi")
        ledger = reader.bridge("--read", repo, "runs", "--limit", "1000")
        if not overview or ledger is None:
            complete_sweep = False
            continue
        rows, complete = inventory(reader, repo, overview)
        database = reader.bridge("--database", repo)
        if not database:
            complete_sweep = False
            continue
        gate = str(Path(database.strip()).resolve())
        active_by_gate.setdefault(gate, set())
        complete_sweep = complete_sweep and complete
        seen = set()
        branches = set()
        candidates = []
        for row in rows:
            branch = row.get("branch")
            newest = branch not in branches
            branches.add(branch)
            # Completed/cancelled history needs no operator action. An old
            # failure superseded by a newer run must not resurrect an alert.
            if row.get("status") in ("completed", "cancelled") or (
                row.get("status") == "failed" and not newest
            ):
                continue
            key = json.dumps([gate, str(repo), row.get("id")])
            seen.add(key)
            candidates.append((key, row))
            if row.get("status") in ("running", "pending"):
                active_by_gate[gate].add(row["id"])
        # Rotate bounded reads so a large fleet cannot starve an older gate.
        # Inventory order above still decides which failures are superseded.
        offset = run_cursors.get(str(repo), 0) % max(1, len(candidates))
        ordered = candidates[offset:] + candidates[:offset]
        for position, (key, row) in enumerate(ordered):
            if time.monotonic() >= reader.deadline:
                run_cursors[str(repo)] = (offset + position) % len(candidates)
                complete_sweep = False
                break
            result = inspect_run(reader, repo, row, runs.get(key, {}), tasks, now, cfg)
            if result is None:
                run_cursors[str(repo)] = (offset + position + 1) % len(candidates)
                complete_sweep = False
                continue
            runs[key], new, active = result
            findings.extend(new)
            if active:
                active_by_gate[gate].add(row["id"])
            else:
                active_by_gate[gate].discard(row["id"])
        else:
            run_cursors[str(repo)] = 0
        if complete:
            for key in list(runs):
                identity = json.loads(key)
                if identity[:2] == [gate, str(repo)] and key not in seen:
                    del runs[key]
    old_pressure = old.get("pressure", {})
    slot_pressure = dict(old_pressure)
    if queued == 0:
        slot_pressure.clear()
    for gate, ids in active_by_gate.items():
        identity = sorted(ids)
        if len(ids) >= cfg["slot_cap"] and queued:
            if old_pressure.get(gate) != identity:
                commands = ", ".join(
                    f"no-mistakes axi abort --run {run_id}" for run_id in identity
                )
                findings.append(
                    f"validation slot pressure: {len(ids)}/{cfg['slot_cap']} active runs with {queued} queued tasks; {pressure(reader, cfg)}; operator: {commands}"
                )
            slot_pressure[gate] = identity
        elif complete_sweep and queued is not None:
            slot_pressure.pop(gate, None)
    if findings:
        # Print before saving suppression: interruption can repeat a notice,
        # but never saves a notice that the standing runner did not capture.
        print("; ".join(" ".join(line.split()) for line in findings), flush=True)
    atomic_write(
        RECORD,
        json.dumps(
            {
                "runs": runs,
                "pressure": slot_pressure,
                "repo_cursor": (cursor + 1) % max(1, len(repos)),
                "run_cursors": run_cursors,
            },
            sort_keys=True,
        )
        + "\n",
    )


def registration(reader, action):
    shim = STATE / (CHECK_ID + ".check.sh")
    if action == "disarm":
        out = reader.run(["bash", BIN / "fm-check-unregister.sh", CHECK_ID])
        if out is None:
            raise ValueError("could not unregister validation monitor")
        print(out.strip())
        return
    if not safe_file(shim):
        raise ValueError("unsafe validation check destination")
    body = "#!/usr/bin/env bash\n"
    for name, path in (
        ("FM_HOME", HOME),
        ("FM_STATE_OVERRIDE", STATE),
        ("FM_DATA_OVERRIDE", DATA),
        ("FM_CONFIG_OVERRIDE", CONFIG),
        ("FM_PROJECTS_OVERRIDE", PROJECTS),
    ):
        body += f"export {name}={shlex.quote(str(path.resolve()))}\n"
    body += f"exec bash {shlex.quote(str(BRIDGE))} check\n"
    backup = shim.read_text() if shim.exists() else None
    atomic_write(shim, body, 0o700)
    if reader.run(["bash", BIN / "fm-check-register.sh", CHECK_ID]) is None:
        if backup is not None:
            atomic_write(shim, backup, 0o700)
        else:
            shim.unlink()
        raise ValueError("could not register validation monitor")
    print("armed: state/validation-monitor.check.sh")


def main():
    action = sys.argv[1]
    if action == "check" and not (CONFIG / "validation-monitor.json").exists():
        return
    if action == "check" and not shutil.which("no-mistakes"):
        return
    if STATE.is_symlink():
        raise ValueError("unsafe validation monitor state directory")
    STATE.mkdir(parents=True, exist_ok=True)
    lock = STATE / ".validation-monitor.lock"
    if not safe_file(lock):
        raise ValueError("unsafe validation monitor lock")
    with lock.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        reader = Reader()
        if action != "check":
            if action == "arm":
                config()
            registration(reader, action)
            return
        if not safe_file(RECORD):
            raise ValueError("unsafe validation monitor record")
        try:
            old = json.loads(read_text(RECORD) or "{}")
        except ValueError:
            old = {}
        check(reader, config(), old)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError) as error:
        print(f"validation monitor: {error}", file=sys.stderr)
        sys.exit(1)

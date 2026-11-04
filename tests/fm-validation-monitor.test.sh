#!/usr/bin/env bash
# Read-only validation detection, attribution, deduplication and check delivery.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-validation-monitor)
MONITOR="$ROOT/bin/fm-validation-monitor.sh"
REPO="$TMP_ROOT/projects/sample"
fm_git_init_commit "$REPO"
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$TMP_ROOT/fakebin"

cat >"$TMP_ROOT/fakebin/tool" <<'PY'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys
import time

root = pathlib.Path(os.environ["FAKE_DIR"])
source = root / pathlib.Path.cwd().name
if not (source / "overview").exists():
    source = root
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls").open("a") as log:
    log.write(json.dumps([name, os.getcwd(), os.environ.get("NM_HOME", ""), args]) + "\n")
if name == "no-mistakes":
    if (root / "unavailable").exists():
        sys.exit(1)
    if (root / "delay").exists():
        time.sleep(10)
    if args == ["axi"]:
        print("repo: " + os.getcwd())
        print((source / "overview").read_text(), end="")
    elif args == ["runs", "--limit", "1000"]:
        print("running fm/task abc1234 2026-11-03 12:00")
    elif len(args) == 4 and args[:3] == ["axi", "status", "--run"]:
        if (root / ("slow-" + args[3])).exists():
            time.sleep(10)
        path = source / (args[3] + ".toon")
        if not path.exists():
            sys.exit(1)
        print(path.read_text(), end="")
    else:
        (root / "MUTATION").write_text(" ".join(args))
        sys.exit(99)
elif name == "gh-axi":
    if (root / "forge-down").exists():
        sys.exit(1)
    assert args[:2] == ["pr", "view"], args
    print("state: " + (root / "pr-state").read_text().strip())
elif name == "tasks-axi":
    assert args[:3] == ["list", "--state", "queued"], args
    count = int((root / "queued").read_text())
    print(f"tasks[{count}]{{id,repo,state}}:")
    for n in range(count):
        print(f"  queued-{n},sample,queued")
PY
chmod +x "$TMP_ROOT/fakebin/tool"
for tool in no-mistakes gh-axi tasks-axi; do
  ln -s tool "$TMP_ROOT/fakebin/$tool"
done
export PATH="$TMP_ROOT/fakebin:$PATH"

world() {
  export FAKE_DIR="$TMP_ROOT/$1"
  export FM_HOME="$FAKE_DIR" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects"
  export NM_HOME="$FAKE_DIR/nm"
  export FM_VALIDATION_MONITOR_NOW=10000
  unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
  mkdir -p "$FAKE_DIR"/{config,data,state,nm}
  printf '{}\n' >"$FAKE_DIR/config/validation-monitor.json"
  printf -- '- sample [no-mistakes] - fixture\n' >"$FAKE_DIR/data/projects.md"
  printf '0\n' >"$FAKE_DIR/queued"
  printf 'OPEN\n' >"$FAKE_DIR/pr-state"
  printf 'count: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n' >"$FAKE_DIR/overview"
}

inventory() {
  local count=$# id
  {
    printf 'count: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n' "$count" "$count" "$count"
    for id in "$@"; do
      printf '  %s,fm/%s,running,%s,""\n' "$id" "$id" "$HEAD_SHA"
    done
  } >"$FAKE_DIR/overview"
}

run_detail() { # id status step step-status [age] [pr]
  local id=$1 status=$2 step=$3 step_status=$4 age=${5:-1s} pr=${6:-}
  {
    printf 'run:\n  id: "%s"\n  branch: fm/%s\n  status: %s\n  head: %s\n  pr: "%s"\n' "$id" "$id" "$status" "$HEAD_SHA" "$pr"
    printf '  steps[1]{step,status,findings,duration_ms}:\n    %s,%s,0,0\n' "$step" "$step_status"
    case "$step_status" in
    awaiting_approval | awaiting_agent | fix_review)
      printf '  awaiting_agent: parked %s\ngate:\n  step: %s\n  status: %s\n' "$age" "$step" "$step_status"
      ;;
    running | fixing)
      printf '  active_steps[1]{step,status,active_for,round}:\n    %s,%s,%s,starting\n' "$step" "$step_status" "$age"
      ;;
    failed) printf 'outcome: failed\n' ;;
    esac
  } >"$FAKE_DIR/$id.toon"
}

worker() { # id [busy|idle|unknown|gone]
  local id=$1 activity=${2:-gone}
  fm_write_meta "$FAKE_DIR/state/$id.meta" "kind=ship" "project=$REPO" \
    "branch=fm/$id" "worktree=$REPO" "spawn_gen=one" "harness=claude"
  if [ "$activity" != gone ]; then
    printf 'backend=orca\nterminal=fixture-%s\n' "$id" >>"$FAKE_DIR/state/$id.meta"
    if [ "$activity" != unknown ]; then
      printf 'monitor\n' >"$FAKE_DIR/state/$id.busy-gen"
      printf 'v1 gen=monitor seq=1 state=%s source=claude-hook event=Stop ts=%s\n' \
        "$activity" "$(date +%s)" >"$FAKE_DIR/state/$id.busy-state"
    fi
  fi
}

check() { bash "$MONITOR" check; }

test_parked_and_dedup() {
  local out
  world parked
  inventory R1
  run_detail R1 running review awaiting_approval 5h
  out=$(check)
  assert_contains "$out" 'parked at review' "old gate not detected"
  assert_contains "$out" 'no-mistakes axi abort --run R1' "exact operator command absent"
  assert_equals "$(check)" "" "same condition repeated"
  run_detail R1 running review awaiting_approval 6h
  assert_equals "$(check)" "" "elapsed time changed the condition key"
  run_detail R1 running test awaiting_agent 1h
  assert_contains "$(check)" 'parked at test' "new gate did not rearm"
  run_detail R1 running test running 1s
  assert_equals "$(check)" "" "young active step raised a false alarm"
  run_detail R1 running test awaiting_agent 1h
  assert_contains "$(check)" 'parked at test' "cleared gate did not rearm"
  pass "parked approval/agent gates use stable per-condition episodes"
}

test_worker_activity() {
  local activity out
  for activity in busy idle unknown gone; do
    world "worker-$activity"
    inventory R1
    run_detail R1 running review awaiting_approval 5h
    worker R1 "$activity"
    out=$(check)
    case "$activity" in
    idle | gone) assert_contains "$out" 'parked at review' "unattended worker not detected: $activity" ;;
    *) assert_equals "$out" "" "uncertain or busy worker treated as unattended: $activity" ;;
    esac
  done
  pass "shared semantic worker activity distinguishes busy, idle, gone and unknown"
}

test_orphan_pr_and_outage() {
  local state out
  for state in MERGED CLOSED; do
    world "orphan-$state"
    inventory R1
    run_detail R1 running ci running 1s https://github.com/o/r/pull/1
    printf '%s\n' "$state" >"$FAKE_DIR/pr-state"
    out=$(check)
    assert_contains "$out" 'orphan run, PR already' "closed PR not detected"
    assert_equals "$(check)" "" "closed PR alert repeated"
    touch "$FAKE_DIR/forge-down"
    assert_equals "$(check)" "" "forge outage raised an orphan"
    rm "$FAKE_DIR/forge-down"
    assert_equals "$(check)" "" "forge outage erased prior orphan fingerprint"
  done
  pass "merged/closed PRs are orphan evidence and failed reads preserve deduplication"
}

test_task_torn_down() {
  world removed-task
  inventory R1
  run_detail R1 running review running 1s
  worker R1 busy
  assert_equals "$(check)" "" "active worker falsely orphaned"
  rm "$FAKE_DIR/state/R1.meta"
  assert_contains "$(check)" 'recorded task has been torn down' "task removal not detected"
  assert_equals "$(check)" "" "task removal repeated"
  pass "a previously attributed run notices task cleanup even while executing"
}

test_task_generation_and_unknown_metadata() {
  world replaced-task
  inventory R1
  run_detail R1 running review running 1s
  worker R1 busy
  assert_equals "$(check)" "" "busy worker fixture alarmed"
  printf '' >"$FAKE_DIR/state/R1.meta"
  assert_equals "$(check)" "" "unreadable task identity was treated as cleanup"
  worker R1 busy
  printf 'spawn_gen=two\n' >>"$FAKE_DIR/state/R1.meta"
  assert_contains "$(check)" 'recorded task has been torn down' "reused task ID hid retired task"
  assert_equals "$(check)" "" "retired task generation alert repeated"
  pass "task generations distinguish cleanup from unreadable identity and ID reuse"
}

test_failed_steps() {
  local step
  for step in push test; do
    world "failed-$step"
    inventory R1
    run_detail R1 failed "$step" failed
    assert_contains "$(check)" "failed at $step" "unattended failure not detected"
    assert_equals "$(check)" "" "failure repeated"
  done
  world failed-busy
  inventory R1
  run_detail R1 failed push failed
  worker R1 busy
  assert_equals "$(check)" "" "worker handling failure was interrupted"
  pass "push and other failed steps report only without a driving worker"
}

test_active_thresholds() {
  world long-step
  inventory R1
  run_detail R1 running push running 11m
  assert_contains "$(check)" 'push active for 660s' "push default threshold not applied"
  assert_equals "$(check)" "" "slow step repeated"
  run_detail R1 running test running 2h
  assert_contains "$(check)" 'test active for 7200s' "new active step not detected"
  printf '{"step_thresholds":{"test":10000}}\n' >"$FAKE_DIR/config/validation-monitor.json"
  assert_equals "$(check)" "" "configured threshold ignored"
  pass "step-specific defaults and configured overrides use active step age"
}

test_observed_age() {
  world observed-age
  inventory R1
  run_detail R1 running review awaiting_agent 0s
  assert_equals "$(check)" "" "first observation invented an old gate"
  FM_VALIDATION_MONITOR_NOW=11900
  export FM_VALIDATION_MONITOR_NOW
  assert_contains "$(check)" 'parked at review for 1900s' "unchanged observation age not used"
  pass "missing CLI age falls back to persisted unchanged-step observation"
}

test_pressure() {
  local out
  world pressure
  inventory R1 R2
  run_detail R1 running review running 1s
  run_detail R2 running test running 1s
  printf '3\n' >"$FAKE_DIR/queued"
  out=$(check)
  assert_contains "$out" 'slot pressure: 2/2 active runs with 3 queued tasks' "full validation slots not detected"
  assert_contains "$out" 'load ' "host load context missing"
  assert_contains "$out" 'swap ' "host swap context missing"
  assert_equals "$(check)" "" "slot pressure repeated"
  printf '0\n' >"$FAKE_DIR/queued"
  assert_equals "$(check)" "" "empty queue raised pressure"
  printf '1\n' >"$FAKE_DIR/queued"
  assert_contains "$(check)" 'slot pressure' "queue pressure did not rearm"
  run_detail R2 cancelled test cancelled
  assert_equals "$(check)" "" "run finishing raised pressure"
  run_detail R2 running test running 1s
  assert_contains "$(check)" 'slot pressure' "freed slot did not rearm pressure"
  pass "slot-cap pressure includes queued work and host load/swap without repeated alerts"
}

test_captured_cli_shapes() {
  local capture
  for capture in parked failed replacement; do
    world "capture-$capture"
    inventory R1
    python3 - "$ROOT/tests/captures/no-mistakes-v1.70.1/$capture.toon" "$FAKE_DIR/R1.toon" "$HEAD_SHA" <<'PY'
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text()
text = re.sub(r'^  id: .*$', '  id: "R1"', text, flags=re.MULTILINE)
text = re.sub(r'^  branch: .*$', '  branch: fm/R1', text, flags=re.MULTILINE)
text = re.sub(r'^  head(?:_sha)?: .*$', '  head: ' + sys.argv[3], text, flags=re.MULTILINE)
pathlib.Path(sys.argv[2]).write_text(text)
PY
    case "$capture" in
    parked) assert_contains "$(check)" 'parked at test' "recorded gate shape was not parsed" ;;
    failed) assert_contains "$(check)" 'failed at push' "recorded failure shape was not parsed" ;;
    replacement) assert_contains "$(check)" 'ci active for' "recorded active-step duration was not parsed" ;;
    esac
  done
  pass "recorded CLI gate, failure and active-step shapes drive monitor findings"
}

test_awaiting_agent_scalar_and_superseded_failure() {
  world awaiting-scalar
  inventory R1
  printf 'run:\n  id: R1\n  branch: fm/R1\n  status: awaiting_agent\n  head: %s\n' "$HEAD_SHA" >"$FAKE_DIR/R1.toon"
  assert_equals "$(check)" "" "scalar gate invented an age"
  FM_VALIDATION_MONITOR_NOW=12000
  export FM_VALIDATION_MONITOR_NOW
  assert_contains "$(check)" 'parked at approval' "awaiting_agent status was treated as executing"
  world superseded-failure
  run_detail R1 failed push failed
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  NEW,fm/R1,completed,%s,""\n  R1,fm/R1,failed,%s,""\n' "$HEAD_SHA" "$HEAD_SHA" >"$FAKE_DIR/overview"
  assert_equals "$(check)" "" "historical failure superseded by success raised an alert"
  pass "scalar awaiting_agent gates are parked and superseded failures stay silent"
}

test_known_gate_slot_groups() {
  local extra="$TMP_ROOT/extra-shared-gate"
  world gate-groups
  fm_git_init_commit "$extra"
  printf '{"repos":["%s"]}\n' "$extra" >"$FAKE_DIR/config/validation-monitor.json"
  inventory R1
  run_detail R1 running review running 1s
  mkdir -p "$FAKE_DIR/extra-shared-gate"
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  R2,fm/R2,running,%s,""\n' "$HEAD_SHA" >"$FAKE_DIR/extra-shared-gate/overview"
  run_detail R2 running test running 1s
  mv "$FAKE_DIR/R2.toon" "$FAKE_DIR/extra-shared-gate/R2.toon"
  printf '2\n' >"$FAKE_DIR/queued"
  assert_contains "$(check)" 'slot pressure: 2/2' "shared gate slots were counted per repo instead of per daemon"
  mkdir -p "$FAKE_DIR/nm-a" "$FAKE_DIR/nm-b"
  cat >"$FAKE_DIR/resolver" <<SH
#!/usr/bin/env bash
case "\$1" in
  "$REPO") printf '%s\n' "$FAKE_DIR/nm-a" ;;
  "$extra") printf '%s\n' "$FAKE_DIR/nm-b" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKE_DIR/resolver"
  printf '%s\n' "$FAKE_DIR/resolver" >"$FAKE_DIR/config/nm-home-resolver"
  unset NM_HOME
  assert_equals "$(check)" "" "separate gate homes were incorrectly combined into slot pressure"
  pass "slot counts combine repositories on one gate but separate resolver-selected gate homes"
}

test_capped_inventory_and_read_only() {
  local before after
  world capped
  inventory R1
  run_detail R1 running ci running 1s
  run_detail HIDDEN running review awaiting_approval 5h
  printf 'count: 1 of 12 total\nruns[1]{id,branch,status,head,pr}:\n  R1,fm/R1,running,%s,""\n' "$HEAD_SHA" >"$FAKE_DIR/overview"
  python3 - "$NM_HOME/state.sqlite" "$REPO" "$HEAD_SHA" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE repos (id TEXT, working_path TEXT)")
db.execute("CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, status TEXT, head_sha TEXT, created_at INTEGER)")
db.execute("INSERT INTO repos VALUES ('sample', ?)", (sys.argv[2],))
for n, ident in enumerate(("R1", "HIDDEN")):
    db.execute("INSERT INTO runs VALUES (?, 'sample', ?, 'running', ?, ?)", (ident, "fm/" + ident, sys.argv[3], 100 - n))
db.commit()
PY
  before=$(shasum -a 256 "$NM_HOME/state.sqlite")
  assert_contains "$(check)" 'validation HIDDEN' "old gate beyond overview cap was lost"
  after=$(shasum -a 256 "$NM_HOME/state.sqlite")
  assert_equals "$after" "$before" "inventory reader wrote no-mistakes state"
  assert_absent "$FAKE_DIR/MUTATION" "monitor invoked a mutating validation command"
  assert_equals "$(git -C "$REPO" status --porcelain)" "" "monitor changed project"
  pass "complete read-only inventory finds a hidden old gate without touching a run or project"
}

test_soft_failures_and_terminal_history() {
  world unavailable
  inventory R1
  run_detail R1 running review awaiting_approval 5h
  assert_contains "$(check)" 'parked at review' "fixture did not alarm"
  touch "$FAKE_DIR/unavailable"
  assert_equals "$(check)" "" "unavailable CLI raised false run evidence"
  rm "$FAKE_DIR/unavailable"
  assert_equals "$(check)" "" "CLI outage erased prior fingerprint"
  run_detail R1 completed review completed
  assert_equals "$(check)" "" "completed run raised alert"
  rm "$FAKE_DIR/config/validation-monitor.json"
  assert_equals "$(check)" "" "disabled check still read"
  pass "unavailable tools and disabled monitoring stay quiet without losing prior evidence"
}

test_bounded_reads_rotate_without_losing_evidence() {
  local start=$SECONDS out
  world bounded
  inventory R1 R2
  run_detail R1 running review running 1s
  run_detail R2 running test awaiting_approval 5h
  touch "$FAKE_DIR/slow-R1"
  out=$(FM_CHECK_TIMEOUT=8 check)
  assert_equals "$out" "" "timed-out run invented a finding"
  out=$(FM_CHECK_TIMEOUT=8 check)
  assert_contains "$out" 'validation R2' "slow earlier run starved the older gate"
  [ "$((SECONDS - start))" -lt 12 ] || fail "timed-out probes exceeded the whole-check bound"
  rm "$FAKE_DIR/slow-R1"
  assert_equals "$(check)" "" "timeout lost already reported gate evidence"
  assert_absent "$FAKE_DIR/MUTATION" "timeout recovery mutated validation"
  pass "bounded reads rotate after a slow run and retain reported condition evidence"
}

test_primary_repo_and_known_gate() {
  local primary="$TMP_ROOT/extra-gate" worker_path="$TMP_ROOT/worker-copy" real_git
  world known-gate
  fm_git_init_commit "$primary"
  mkdir -p "$worker_path"
  real_git=$(command -v git)
  cat >"$TMP_ROOT/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = "$worker_path" ] && [ "\${3:-}" = worktree ]; then
  printf 'worktree %s\\n\\nworktree %s\\n' "$primary" "$worker_path"
else
  exec "$real_git" "\$@"
fi
SH
  chmod +x "$TMP_ROOT/fakebin/git"
  printf '{"repos":["%s"]}\n' "$worker_path" >"$FAKE_DIR/config/validation-monitor.json"
  inventory R1
  run_detail R1 running review awaiting_approval 5h
  check >/dev/null
  python3 - "$FAKE_DIR/calls" "$REPO" "$primary" "$worker_path" <<'PY'
import json
import sys
calls = [json.loads(line) for line in open(sys.argv[1])]
dirs = {call[1] for call in calls if call[0] == "no-mistakes"}
assert set(sys.argv[2:4]) <= dirs, dirs
assert sys.argv[4] not in dirs, dirs
assert all(call[3][0] in ("axi", "runs") for call in calls if call[0] == "no-mistakes")
PY
  rm "$TMP_ROOT/fakebin/git"
  pass "registered projects and known gates are queried from primary copies, never workers"
}

test_registration_and_check_wake() {
  local out
  world registered
  inventory R1
  run_detail R1 running review awaiting_approval 5h
  out=$(bash "$MONITOR" arm)
  assert_contains "$out" 'armed:' "monitor did not arm"
  # Run through the public standing-check runner, not a private detector call.
  out=$(bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-x-lib.sh"
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    . "$1/bin/fm-supervision-lib.sh"
    FM_ROOT=$1
    fm_supervision_run_due_checks "$FM_HOME/state" 300 30 false
  ' _ "$ROOT")
  assert_grep "check: $FAKE_DIR/state/validation-monitor.check.sh: validation R1" \
    "$FAKE_DIR/state/.wake-queue" "standing check did not deliver a plain check wake"
  assert_grep 'parked at review' "$FAKE_DIR/state/.wake-queue" "wake lost the plain reason"
  assert_equals "$(wc -l <"$FAKE_DIR/state/.wake-queue" | tr -d ' ')" 1 "check output was not one line"
  bash "$MONITOR" disarm >/dev/null
  assert_absent "$FAKE_DIR/state/validation-monitor.check.sh" "disarm left executable shim"
  assert_absent "$FAKE_DIR/state/validation-monitor.check-trust" "disarm left check registration"
  assert_absent "$FAKE_DIR/MUTATION" "standing check mutated validation"
  pass "authenticated monitor integrates with the existing standing check wake mechanism"
}

test_symlink_registration_refused() {
  world unsafe
  printf 'untouched\n' >"$FAKE_DIR/target"
  ln -s "$FAKE_DIR/target" "$FAKE_DIR/state/validation-monitor.check.sh"
  if bash "$MONITOR" arm >/dev/null 2>&1; then fail "symlink shim was accepted"; fi
  assert_equals "$(cat "$FAKE_DIR/target")" untouched "registration followed symlink"
  pass "unsafe registration paths are refused without following symlinks"
}

fm_test_run \
  test_parked_and_dedup \
  test_worker_activity \
  test_orphan_pr_and_outage \
  test_task_torn_down \
  test_task_generation_and_unknown_metadata \
  test_failed_steps \
  test_active_thresholds \
  test_observed_age \
  test_pressure \
  test_captured_cli_shapes \
  test_awaiting_agent_scalar_and_superseded_failure \
  test_known_gate_slot_groups \
  test_capped_inventory_and_read_only \
  test_soft_failures_and_terminal_history \
  test_bounded_reads_rotate_without_losing_evidence \
  test_primary_repo_and_known_gate \
  test_registration_and_check_wake \
  test_symlink_registration_refused

#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a home-scoped temp root with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the
# task's meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise behavior directly: fm-teardown is run as a subprocess against a
# fake FM_ROOT (built so the real script resolves into it), with stub helper scripts.
# Nothing is sourced. The fm-spawn side is verified both structurally (the source has
# the contract lines) and behaviorally (the mkdir + meta-write pattern it uses).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
TASK_TMP_PARENTS=

cleanup() {
  local parent
  for parent in $TASK_TMP_PARENTS; do
    rmdir "$parent" 2>/dev/null || true
  done
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

task_tmp_for_home() {
  local home=$1 id=$2 tag
  tag=$(FM_HOME="$home" FM_ROOT="$home" bash -c '. "$1"; fm_backend_hometag' _ "$ROOT/bin/fm-backend-hometag-lib.sh")
  printf '/tmp/fm-%s/%s' "$tag" "$id"
}

task_tmp_for_root_and_home() {
  local root=$1 home=$2 id=$3 tag
  tag=$(FM_HOME="$home" FM_ROOT="$root" bash -c '. "$1"; fm_backend_hometag' _ "$ROOT/bin/fm-backend-hometag-lib.sh")
  printf '/tmp/fm-%s/%s' "$tag" "$id"
}

remember_task_tmp_parent() {
  TASK_TMP_PARENTS="$TASK_TMP_PARENTS ${1%/*}"
}

# Build a fake FM_ROOT so the real fm-teardown.sh (symlinked in) resolves FM_ROOT to
# it via its BASH_SOURCE computation. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # fm-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/fm-backend-hometag-lib.sh" "$fake/bin/fm-backend-hometag-lib.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report not-compatible so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_compatible() { return 1; }
SH
  if [ "$tasktmp" = __AUTO__ ]; then
    tasktmp=$(task_tmp_for_home "$fake" "$id")
  fi
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-spawn side ---

test_spawn_contract_and_mkdir_pattern() {
  # Structural: fm-spawn must create the gotmp dir, record tasktmp in meta, and export
  # GOTMPDIR into the pane. Assert the contract lines are present in the source.
  # shellcheck disable=SC2016  # single quotes are deliberate: these are literal source strings
  grep -F 'mkdir -p "$TASK_TMP/gotmp"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: mkdir of gotmp under TASK_TMP"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'TASK_TMP="/tmp/fm-$(fm_backend_hometag)/$ID"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: home-scoped task temp root"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'echo "tasktmp=$TASK_TMP"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: tasktmp= line in meta write"
  grep -F 'export GOTMPDIR=' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: GOTMPDIR export into pane"
  # Behavioral: the mkdir + meta-write pattern spawn uses must produce a gotmp dir and
  # a meta line whose value the teardown grep (tasktmp=, cut -d= -f2-) reads back whole.
  local id=spawn-sim-z1
  local sim_root="$TMP_ROOT/$id-root"
  local task_tmp="$sim_root/tmp/fm-$id"
  mkdir -p "$sim_root/state"
  # Replicate spawn's exact mkdir + meta-write lines.
  TASK_TMP="$task_tmp"
  mkdir -p "$TASK_TMP/gotmp"
  {
    echo "tasktmp=$TASK_TMP"
  } > "$sim_root/state/$id.meta"
  [ -d "$task_tmp/gotmp" ] || fail "simulated spawn did not create gotmp dir"
  # Teardown reads tasktmp= with `grep '^tasktmp=' | cut -d= -f2-`; round-trip it.
  local read_back
  read_back=$(grep '^tasktmp=' "$sim_root/state/$id.meta" | cut -d= -f2-)
  [ "$read_back" = "$task_tmp" ] \
    || fail "tasktmp value not round-tripped by teardown's grep|cut (got '$read_back')"
  pass "fm-spawn creates gotmp dir and records tasktmp in meta"
}

test_tasktmp_path_is_home_scoped() {
  local id=same-id-z1
  local home_a="$TMP_ROOT/home-a"
  local home_b="$TMP_ROOT/home-b"
  mkdir -p "$home_a" "$home_b"
  local tmp_a tmp_b
  tmp_a=$(task_tmp_for_home "$home_a" "$id")
  tmp_b=$(task_tmp_for_home "$home_b" "$id")
  [ "$tmp_a" != "$tmp_b" ] \
    || fail "same task id in different homes produced the same task temp root"
  pass "task temp root is home-scoped"
}

test_tasktmp_path_uses_home_not_checkout() {
  local id=same-id-z1
  local checkout="$TMP_ROOT/shared-checkout"
  local home_a="$TMP_ROOT/primary-home-a"
  local home_b="$TMP_ROOT/primary-home-b"
  mkdir -p "$checkout" "$home_a" "$home_b"
  local tmp_a tmp_b
  tmp_a=$(task_tmp_for_root_and_home "$checkout" "$home_a" "$id")
  tmp_b=$(task_tmp_for_root_and_home "$checkout" "$home_b" "$id")
  [ "$tmp_a" != "$tmp_b" ] \
    || fail "same task id in different homes sharing a checkout produced the same task temp root"
  pass "task temp root is scoped by FM_HOME, not checkout"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local fake task_tmp
  fake=$(make_fake_root "$id" __AUTO__)
  task_tmp=$(grep '^tasktmp=' "$fake/state/$id.meta" | cut -d= -f2-)
  remember_task_tmp_parent "$task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/fm-backend-hometag-lib.sh" "$fake/bin/fm-backend-hometag-lib.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_compatible() { return 1; }
SH
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local fake task_tmp
  fake=$(make_fake_root "$id" __AUTO__)
  task_tmp=$(grep '^tasktmp=' "$fake/state/$id.meta" | cut -d= -f2-)
  remember_task_tmp_parent "$task_tmp"
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_refuses_unexpected_tasktmp_dir() {
  local id=td-unsafe-z5
  local task_tmp="$TMP_ROOT/unsafe-fm-$id"
  mkdir -p "$task_tmp/gotmp"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  if bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1; then
    fail "teardown succeeded with an unexpected tasktmp path"
  fi
  [ -d "$task_tmp/gotmp" ] \
    || fail "teardown removed an unexpected tasktmp path"
  pass "fm-teardown refuses unexpected tasktmp paths"
}

test_teardown_validates_tasktmp_before_backend_cleanup() {
  local id=td-unsafe-early-z6
  local task_tmp="$TMP_ROOT/unsafe-fm-$id"
  mkdir -p "$task_tmp/gotmp"
  local fake out
  fake=$(make_fake_root "$id" "$task_tmp")
  out="$TMP_ROOT/$id.out"
  if bash "$fake/bin/fm-teardown.sh" "$id" >"$out" 2>&1; then
    fail "teardown succeeded with an unexpected tasktmp path"
  fi
  [ -f "$fake/state/$id.meta" ] \
    || fail "teardown removed meta before refusing unsafe tasktmp"
  [ -d "$task_tmp/gotmp" ] \
    || fail "teardown removed an unexpected tasktmp path"
  grep -F 'teardown complete' "$out" >/dev/null \
    && fail "teardown completed after refusing unsafe tasktmp"
  pass "fm-teardown validates tasktmp before destructive cleanup"
}

test_spawn_contract_and_mkdir_pattern
test_tasktmp_path_is_home_scoped
test_tasktmp_path_uses_home_not_checkout
test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_teardown_refuses_unexpected_tasktmp_dir
test_teardown_validates_tasktmp_before_backend_cleanup

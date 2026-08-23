#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a home-scoped temp root with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the
# task's meta. fm-teardown validates tasktmp= and removes the whole root.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

remember_task_tmp_parent() {
  TASK_TMP_PARENTS="$TASK_TMP_PARENTS ${1%/*}"
}

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/fakebin" "$fake/state"
  cat > "$fake/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/fakebin/tmux"
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
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # Lifecycle serialization, status presentation retirement, and shared adapter
  # ownership are sourced by teardown.
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
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
  cat > "$fake/bin/fm-remote-job-reap-orphans.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-remote-job-reap-orphans.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
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
  PATH="$fake/fakebin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_tasktmp_path_is_home_scoped() {
  local id=same-id-z1 home_a="$TMP_ROOT/home-a" home_b="$TMP_ROOT/home-b" tmp_a tmp_b
  mkdir -p "$home_a" "$home_b"
  tmp_a=$(task_tmp_for_home "$home_a" "$id")
  tmp_b=$(task_tmp_for_home "$home_b" "$id")
  [ "$tmp_a" != "$tmp_b" ] || fail "same task id in different homes produced the same task temp root"
  pass "task temp root is home-scoped"
}

test_teardown_uses_state_override_home_for_tasktmp() {
  local id=td-state-home-z2 fake home task_tmp
  home="$TMP_ROOT/$id-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  task_tmp=$(task_tmp_for_home "$home" "$id")
  fake=$(make_fake_root "$id" "$task_tmp")
  mv "$fake/state/$id.meta" "$home/state/$id.meta"
  remember_task_tmp_parent "$task_tmp"
  mkdir -p "$task_tmp/gotmp"
  PATH="$fake/fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown did not validate tasktmp against the FM_STATE_OVERRIDE home"
  [ ! -e "$task_tmp" ] || fail "teardown with FM_STATE_OVERRIDE did not remove the home-scoped tasktmp dir"
  pass "fm-teardown validates tasktmp against FM_STATE_OVERRIDE's home when FM_HOME is unset"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/fakebin" "$fake/state"
  cat > "$fake/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/fakebin/tmux"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/fm-backend-hometag-lib.sh" "$fake/bin/fm-backend-hometag-lib.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
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
  cat > "$fake/bin/fm-remote-job-reap-orphans.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-remote-job-reap-orphans.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
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
  PATH="$fake/fakebin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
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
  PATH="$fake/fakebin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_refuses_unexpected_tasktmp_dir() {
  local id=td-unsafe-z5 task_tmp fake
  task_tmp="$TMP_ROOT/unsafe-fm-$id"
  mkdir -p "$task_tmp/gotmp"
  fake=$(make_fake_root "$id" "$task_tmp")
  if PATH="$fake/fakebin:$PATH" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1; then
    fail "teardown succeeded with an unexpected tasktmp path"
  fi
  [ -d "$task_tmp/gotmp" ] || fail "teardown removed an unexpected tasktmp path"
  [ -f "$fake/state/$id.meta" ] || fail "teardown mutated state before refusing unsafe tasktmp"
  pass "fm-teardown refuses unexpected tasktmp paths before cleanup"
}

test_teardown_preserves_legacy_tasktmp_and_retires_task() {
  local id=td-legacy-z6 task_tmp fake
  task_tmp="/tmp/fm-$id"
  rm -rf "$task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'legacy\n' > "$task_tmp/gotmp/build-artifact"
  fake=$(make_fake_root "$id" "$task_tmp")
  PATH="$fake/fakebin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown rejected a legacy tasktmp path"
  [ -f "$task_tmp/gotmp/build-artifact" ] || fail "teardown removed the unverifiable legacy tasktmp root"
  [ ! -e "$fake/state/$id.meta" ] || fail "teardown retained task metadata for a legacy tasktmp path"
  rm -rf "$task_tmp"
  pass "fm-teardown preserves legacy task temp roots while retiring their tasks"
}

test_tasktmp_path_is_home_scoped
test_teardown_removes_tasktmp_dir
test_teardown_uses_state_override_home_for_tasktmp
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_teardown_refuses_unexpected_tasktmp_dir
test_teardown_preserves_legacy_tasktmp_and_retires_task

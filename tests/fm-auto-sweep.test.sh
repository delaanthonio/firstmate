#!/usr/bin/env bash
# Behavior tests for the review-comment auto-sweep:
#   A. fm-pr-check.sh - the generated check arms both the merge poll and the
#      review-comment auto-sweep detector.
#   B. fm-auto-sweep.sh --check - the detector's wake/silence contract.
#   C. fm-auto-sweep.sh <id> <url> - the spawner's idempotency and scaffolding.
#
# gh is faked via a PATH shim that dispatches on its args and cats fixtures, so
# no network or real PR is needed. The spawner test points FM_ROOT at a temp dir
# holding fm-guard.sh/fm-spawn.sh stubs so the real fm-auto-sweep.sh runs end to
# end without tmux or treehouse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRCHECK="$ROOT/bin/fm-pr-check.sh"
SWEEP="$ROOT/bin/fm-auto-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-sweep)

PR_URL="https://github.com/acme/widget/pull/42"

# A fake gh that reads scenario fixtures from FAKE_* files. Each test rewrites the
# fixtures, so one shim serves every scenario.
install_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
all="$*"
case "$1 ${2:-}" in
  "pr view")
    case "$all" in
      *"--json headRefName"*) cat "${FAKE_BRANCH_FILE:-/dev/null}" ;;
      *"--json state,statusCheckRollup,reviews,comments"*)
        [ -s "${FAKE_PRVIEW_FILE:-/dev/null}" ] || exit 1
        cat "$FAKE_PRVIEW_FILE" ;;
      *) exit 0 ;;
    esac ;;
  "api user") cat "${FAKE_SELF_FILE:-/dev/null}" ;;
  "api graphql") cat "${FAKE_THREADS_FILE:-/dev/null}" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
install_fake_gh "$FAKEBIN"
export FAKE_PRVIEW_FILE="$TMP_ROOT/prview.json"
export FAKE_THREADS_FILE="$TMP_ROOT/threads.txt"
export FAKE_SELF_FILE="$TMP_ROOT/self.txt"
export FAKE_BRANCH_FILE="$TMP_ROOT/branch.txt"
printf 'me\n' > "$FAKE_SELF_FILE"

GREEN_CR_PRVIEW='{"state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"state":"SUCCESS"}],"reviews":[{"author":{"login":"coderabbitai[bot]"}}],"comments":[]}'

# --- A. fm-pr-check.sh: generated check arms merge + auto-sweep --------------
test_pr_check_arms_auto_sweep() {
  local home="$TMP_ROOT/prcheck-home" id=arm-sweep-b1 check
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" "window=s:fm-$id" "worktree=$home/wt" "project=$home/proj"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_HOME="$home" "$PRCHECK" "$id" "$PR_URL" >/dev/null 2>&1 || fail "fm-pr-check.sh failed"
  check="$home/state/$id.check.sh"
  assert_present "$check" "check.sh was not written"
  assert_grep 'echo "merged"' "$check" "check.sh lost the merge poll"
  assert_grep "fm-auto-sweep.sh\" --check '$id' '$PR_URL'" "$check" "check.sh did not arm the auto-sweep detector"
  pass "fm-pr-check.sh: check.sh polls for merge AND review-comment auto-sweep"
}

# --- B. fm-auto-sweep.sh --check: the detector contract ----------------------
run_check() {
  local id=$1
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_HOME="$TMP_ROOT/check-home" "$SWEEP" --check "$id" "$PR_URL" 2>/dev/null
}

test_check_emits_when_green_reviewed_and_threads() {
  mkdir -p "$TMP_ROOT/check-home/state"
  printf '%s\n' "$GREEN_CR_PRVIEW" > "$FAKE_PRVIEW_FILE"
  printf 'PRRT_thread1\n' > "$FAKE_THREADS_FILE"
  local out
  out=$(run_check sweep-emit-c1)
  assert_contains "$out" "auto-sweep: sweep-emit-c1 $PR_URL" "detector did not emit on green + CodeRabbit + open threads"
  pass "fm-auto-sweep --check: emits one auto-sweep line when green, reviewed, and threads remain"
}

test_check_silent_without_threads() {
  printf '%s\n' "$GREEN_CR_PRVIEW" > "$FAKE_PRVIEW_FILE"
  : > "$FAKE_THREADS_FILE"
  local out
  out=$(run_check sweep-nothreads-c2)
  [ -z "$out" ] || fail "detector must stay silent when no unresolved threads remain (got: $out)"
  pass "fm-auto-sweep --check: silent when there are no open threads to sweep"
}

test_check_silent_when_not_green() {
  printf '%s\n' '{"state":"OPEN","statusCheckRollup":[{"conclusion":"FAILURE"}],"reviews":[{"author":{"login":"coderabbitai[bot]"}}],"comments":[]}' > "$FAKE_PRVIEW_FILE"
  printf 'PRRT_thread1\n' > "$FAKE_THREADS_FILE"
  local out
  out=$(run_check sweep-red-c3)
  [ -z "$out" ] || fail "detector must stay silent while checks are red (got: $out)"
  pass "fm-auto-sweep --check: silent while CI is not green"
}

test_check_silent_when_coderabbit_absent() {
  printf '%s\n' '{"state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"}],"reviews":[{"author":{"login":"humanreviewer"}}],"comments":[]}' > "$FAKE_PRVIEW_FILE"
  printf 'PRRT_thread1\n' > "$FAKE_THREADS_FILE"
  local out
  out=$(run_check sweep-nocr-c4)
  [ -z "$out" ] || fail "detector must wait until CodeRabbit has reviewed (got: $out)"
  pass "fm-auto-sweep --check: silent until CodeRabbit has reviewed"
}

test_check_idempotent_after_sweep() {
  mkdir -p "$TMP_ROOT/check-home/state"
  printf '%s\n' "$GREEN_CR_PRVIEW" > "$FAKE_PRVIEW_FILE"
  printf 'PRRT_thread1\n' > "$FAKE_THREADS_FILE"
  : > "$TMP_ROOT/check-home/state/sweep-once-c5.auto-swept"
  local out
  out=$(run_check sweep-once-c5)
  [ -z "$out" ] || fail "detector must stay silent once the sweep sentinel exists (got: $out)"
  pass "fm-auto-sweep --check: one sweep per PR (silent after the sentinel)"
}

test_check_failsafe_on_bad_url() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_HOME="$TMP_ROOT/check-home" "$SWEEP" --check bad-url-c6 "not-a-pr-url" 2>/dev/null)
  [ -z "$out" ] || fail "detector must fail safe (silent) on an unparseable URL (got: $out)"
  pass "fm-auto-sweep --check: fails safe and silent on a bad URL"
}

# --- C. fm-auto-sweep.sh spawner --------------------------------------------
# A temp FM_ROOT with stub fm-guard.sh / fm-spawn.sh, so the real fm-auto-sweep.sh
# scaffolds and "spawns" without tmux/treehouse.
spawn_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/state" "$home/data"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$home/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$home/spawn-args"
SH
  chmod +x "$home/bin/fm-guard.sh" "$home/bin/fm-spawn.sh"
}

run_spawn() {
  local home=$1; shift
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' "$SWEEP" "$@" 2>&1
}

test_spawn_scaffolds_and_dispatches() {
  local home="$TMP_ROOT/spawn-home" id=do-sweep-d1 out
  spawn_home "$home"
  printf 'fm/%s\n' "$id" > "$FAKE_BRANCH_FILE"
  fm_write_meta "$home/state/$id.meta" "window=s:fm-$id" "worktree=$home/wt" "project=$home/projects/widget"
  out=$(run_spawn "$home" "$id" "$PR_URL") || fail "spawner failed: $out"
  assert_present "$home/state/$id.auto-swept" "spawner did not write the one-per-PR sentinel"
  assert_present "$home/data/$id-sweep/brief.md" "spawner did not scaffold the sweep brief"
  assert_grep "Never merge" "$home/data/$id-sweep/brief.md" "sweep brief must forbid merging"
  assert_grep "git push origin" "$home/data/$id-sweep/brief.md" "sweep brief must push fixes to the PR branch"
  assert_grep "$id-sweep" "$home/spawn-args" "fm-spawn was not invoked for the sweep crewmate"
  assert_grep "$home/projects/widget" "$home/spawn-args" "fm-spawn was not pointed at the PR's project"
  pass "fm-auto-sweep spawn: writes sentinel, scaffolds a no-merge sweep brief, dispatches the crewmate"
}

test_spawn_idempotent() {
  local home="$TMP_ROOT/spawn-idem" id=once-sweep-d2 out
  spawn_home "$home"
  fm_write_meta "$home/state/$id.meta" "window=s:fm-$id" "worktree=$home/wt" "project=$home/projects/widget"
  : > "$home/state/$id.auto-swept"
  out=$(run_spawn "$home" "$id" "$PR_URL") || fail "idempotent spawner should exit 0"
  assert_contains "$out" "already dispatched" "spawner must report it already swept this PR"
  assert_absent "$home/data/$id-sweep/brief.md" "spawner must not re-scaffold once swept"
  assert_absent "$home/spawn-args" "spawner must not re-dispatch once swept"
  pass "fm-auto-sweep spawn: idempotent - one sweep per PR, no re-dispatch"
}

test_spawn_requires_meta_and_project() {
  local home="$TMP_ROOT/spawn-nometa" out status
  spawn_home "$home"
  out=$(run_spawn "$home" no-meta-d3 "$PR_URL"); status=$?
  expect_code 1 "$status" "missing meta"
  assert_contains "$out" "no meta for task" "spawner must refuse without a meta"

  fm_write_meta "$home/state/no-proj-d4.meta" "window=s:fm-x" "worktree=$home/wt"
  out=$(run_spawn "$home" no-proj-d4 "$PR_URL"); status=$?
  expect_code 1 "$status" "missing project"
  assert_contains "$out" "no project=" "spawner must refuse without a project"
  pass "fm-auto-sweep spawn: refuses without meta or project"
}

test_pr_check_arms_auto_sweep
test_check_emits_when_green_reviewed_and_threads
test_check_silent_without_threads
test_check_silent_when_not_green
test_check_silent_when_coderabbit_absent
test_check_idempotent_after_sweep
test_check_failsafe_on_bad_url
test_spawn_scaffolds_and_dispatches
test_spawn_idempotent
test_spawn_requires_meta_and_project

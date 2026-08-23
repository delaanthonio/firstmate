#!/usr/bin/env bash
# Behavior tests for the shared standing check-script runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$ROOT/bin/fm-x-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-standing-checks)
FM_ROOT=$ROOT

register_check() {
  local script=$1 state id hash
  state=${script%/*}
  id=$(basename "$script" .check.sh)
  chmod 700 "$script"
  hash=$(fm_custom_check_sha256 "$script") || fail "could not hash custom check fixture"
  printf 'fm-custom-check-v1\n%s\n' "$hash" > "$state/$id.check-trust"
  chmod 600 "$state/$id.check-trust"
}

use_state_home() {
  FM_HOME=${1%/state}
}

counting_check() {
  local script=$1 count_file=$2 output=${3:-ready}
  cat > "$script" <<SH
#!/usr/bin/env bash
n=\$(( \$(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "$count_file"
printf '%s\n' "$output"
SH
  register_check "$script"
}

test_due_check_appends_wake_and_stamps_schedule() {
  local state="$TMP_ROOT/due/state" count rc queue
  mkdir -p "$state"
  count="$state/count"
  use_state_home "$state"
  counting_check "$state/task.check.sh" "$count" "merged"
  fm_supervision_run_due_checks "$state" 300 5 false; rc=$?
  expect_code 0 "$rc" "due actionable check should return 0"
  [ "$(cat "$count")" = 1 ] || fail "check should run exactly once"
  queue=$(cat "$state/.wake-queue")
  assert_contains "$queue" "check: $state/task.check.sh: merged" "wake queue should contain the check reason"
  assert_present "$state/.last-check" "due sweep should stamp .last-check after enqueue"
  pass "fm_supervision_run_due_checks: due actionable check appends wake and stamps schedule"
}

test_not_due_check_does_not_run_again() {
  local state="$TMP_ROOT/not-due/state" count rc
  mkdir -p "$state"
  count="$state/count"
  use_state_home "$state"
  counting_check "$state/task.check.sh" "$count" "ready"
  fm_supervision_run_due_checks "$state" 300 5 false >/dev/null || fail "first due run should be actionable"
  fm_supervision_run_due_checks "$state" 300 5 false; rc=$?
  expect_code 1 "$rc" "fresh .last-check should make the second sweep not due"
  [ "$(cat "$count")" = 1 ] || fail "not-due check should not run again"
  pass "fm_supervision_run_due_checks: not-due check does not double-run"
}

test_missing_and_silent_checks_do_not_queue() {
  local missing="$TMP_ROOT/missing/state" silent="$TMP_ROOT/silent/state" rc
  mkdir -p "$missing" "$silent"
  use_state_home "$missing"
  fm_supervision_run_due_checks "$missing" 300 5 false; rc=$?
  expect_code 1 "$rc" "missing checks should be a no-op"
  assert_absent "$missing/.wake-queue" "missing checks should not create a wake queue"
  cat > "$silent/quiet.check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  register_check "$silent/quiet.check.sh"
  use_state_home "$silent"
  fm_supervision_run_due_checks "$silent" 300 5 false; rc=$?
  expect_code 1 "$rc" "silent check should not be actionable"
  assert_absent "$silent/.wake-queue" "silent check should not queue a wake"
  assert_present "$silent/.last-check" "silent due sweep should still stamp .last-check"
  pass "fm_supervision_run_due_checks: missing and silent checks stay quiet"
}

test_erroring_check_fails_open_and_logs_when_requested() {
  local state="$TMP_ROOT/error/state" out rc
  mkdir -p "$state"
  use_state_home "$state"
  cat > "$state/fail.check.sh" <<'SH'
#!/usr/bin/env bash
echo "bad credentials" >&2
exit 7
SH
  register_check "$state/fail.check.sh"
  out=$(fm_supervision_run_due_checks "$state" 300 5 true 2>&1); rc=$?
  expect_code 1 "$rc" "erroring check should fail open"
  assert_contains "$out" "failed open" "erroring check should log fail-open context"
  assert_absent "$state/.wake-queue" "erroring check should not queue a wake"
  pass "fm_supervision_run_due_checks: erroring check fails open"
}

test_timeout_check_fails_open_and_stamps_schedule() {
  local state="$TMP_ROOT/timeout/state" start elapsed out rc
  mkdir -p "$state"
  use_state_home "$state"
  cat > "$state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
sleep 5
printf 'late\n'
SH
  register_check "$state/slow.check.sh"
  start=$SECONDS
  out=$(fm_supervision_run_due_checks "$state" 300 1 true 2>&1); rc=$?
  elapsed=$((SECONDS - start))
  expect_code 1 "$rc" "timed-out check should fail open"
  [ "$elapsed" -lt 4 ] || fail "timeout should bound runtime, elapsed ${elapsed}s"
  assert_contains "$out" "timed out" "timeout should log fail-open context"
  assert_absent "$state/.wake-queue" "timed-out check should not queue a wake"
  assert_present "$state/.last-check" "timed-out due sweep should stamp .last-check"
  pass "fm_supervision_run_due_checks: timeout fails open without wedging"
}

test_concurrent_runner_lock_prevents_double_run() {
  local state="$TMP_ROOT/locked/state" count rc holder owner lock
  mkdir -p "$state"
  count="$state/count"
  use_state_home "$state"
  counting_check "$state/task.check.sh" "$count" "ready"
  lock="$state/.last-check.lock"
  owner=$(mktemp -d "$state/.last-check.lock.owner.XXXXXX") || fail "could not create lock owner fixture"
  sleep 10 &
  holder=$!
  printf '%s\n' "$holder" > "$owner/pid"
  ln -s "$owner" "$lock" || fail "could not publish lock fixture"
  fm_supervision_run_due_checks "$state" 300 5 false; rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -f "$lock"
  rm -f "$owner/pid"
  rmdir "$owner"
  expect_code 1 "$rc" "held check lock should make runner skip"
  assert_absent "$count" "held check lock should prevent the check from running"
  pass "fm_supervision_run_due_checks: held lock prevents concurrent check execution"
}

test_unauthenticated_check_is_rejected_without_execution() {
  local state="$TMP_ROOT/rejected/state" count rc
  mkdir -p "$state"
  use_state_home "$state"
  count="$state/count"
  cat > "$state/rogue.check.sh" <<SH
#!/usr/bin/env bash
printf '1\n' > "$count"
printf 'forged wake\n'
SH
  chmod 700 "$state/rogue.check.sh"
  fm_supervision_run_due_checks "$state" 300 5 false; rc=$?
  expect_code 0 "$rc" "rejected unauthenticated check should create an actionable wake"
  assert_absent "$count" "unauthenticated custom check must never execute"
  assert_contains "$FM_SUP_CHECK_OUTPUT" "rejected unauthenticated state checks" \
    "rejected check should surface an authentication wake"
  assert_grep "rejected unauthenticated state checks" "$state/.wake-queue" \
    "authentication rejection should be durably queued"
  pass "fm_supervision_run_due_checks: unauthenticated custom checks are rejected without execution"
}

test_leading_dangling_check_does_not_hide_valid_due_check() {
  local state="$TMP_ROOT/dangling-before-valid/state" count rc
  mkdir -p "$state"
  use_state_home "$state"
  count="$state/count"
  ln -s "$state/missing-check" "$state/aaa.check.sh"
  counting_check "$state/zzz.check.sh" "$count" "ready"
  fm_supervision_run_due_checks "$state" 300 5 false; rc=$?
  expect_code 0 "$rc" "valid due check should remain actionable after a leading dangling entry"
  [ "$(cat "$count")" = 1 ] || fail "leading dangling entry prevented the valid due check from executing"
  assert_contains "$FM_SUP_CHECK_OUTPUT" "ready" \
    "valid due check output was lost after classifying a leading dangling entry"
  assert_contains "$FM_SUP_CHECK_OUTPUT" "rejected unauthenticated state checks: $state/aaa.check.sh" \
    "leading dangling entry was not reported with the valid due check"
  assert_grep "check: $state/zzz.check.sh: ready" "$state/.wake-queue" \
    "valid due check wake was not durably queued after a leading dangling entry"
  assert_grep "rejected unauthenticated state checks: $state/aaa.check.sh" "$state/.wake-queue" \
    "leading dangling entry was not durably reported with the valid due check"
  pass "fm_supervision_run_due_checks: dangling entries do not hide valid due checks"
}

test_merged_pr_retirement_waits_for_durable_wake() {
  local state="$TMP_ROOT/merged-wake-failure/state" rc
  mkdir -p "$state"
  use_state_home "$state"
  touch "$state/pr5.check.sh" "$state/pr5.check-trust"
  (
    fm_pr_poll_snapshot_capture() {
      FM_PR_POLL_SNAPSHOT_PROVIDER=github
      FM_PR_POLL_SNAPSHOT_URL=https://example.invalid/pr/5
      FM_PR_POLL_SNAPSHOT_HOST=example.invalid
      FM_PR_POLL_SNAPSHOT_PATH=pr/5
      FM_PR_POLL_SNAPSHOT_NUMBER=5
      return 0
    }
    fm_supervision_run_check_script() {
      printf 'merged\n' > "$3"
      FM_SUP_CHECK_STATUS=0
    }
    fm_wake_append() { return 1; }
    fm_pr_poll_retirement_publish() { touch "$state/retirement-published"; }
    fm_pr_poll_retirement_recover_one() { touch "$state/retirement-recovered"; }
    fm_supervision_run_due_checks "$state" 300 5 false
  ); rc=$?
  expect_code 2 "$rc" "failed durable wake append should return 2"
  assert_present "$state/pr5.check.sh" "failed wake append should retain the PR check for retry"
  assert_absent "$state/retirement-published" "failed wake append should not publish PR retirement"
  assert_absent "$state/retirement-recovered" "failed wake append should not recover PR retirement"
  assert_absent "$state/.last-check" "failed wake append should leave the standing check immediately due"
  pass "fm_supervision_run_due_checks: merged PR retirement follows durable wake append"
}

test_rejected_check_append_failure_keeps_cadence_due() {
  local state="$TMP_ROOT/rejected-wake-failure/state" rc
  mkdir -p "$state"
  use_state_home "$state"
  touch "$state/rogue.check.sh"
  (
    fm_wake_append() { return 1; }
    fm_supervision_run_due_checks "$state" 300 5 false
  ); rc=$?
  expect_code 2 "$rc" "failed rejection wake append should return 2"
  assert_absent "$state/.last-check" "failed rejection wake append should leave the standing check immediately due"
  pass "fm_supervision_run_due_checks: rejected checks advance cadence after durable wake"
}

test_due_check_appends_wake_and_stamps_schedule
test_not_due_check_does_not_run_again
test_missing_and_silent_checks_do_not_queue
test_erroring_check_fails_open_and_logs_when_requested
test_timeout_check_fails_open_and_stamps_schedule
test_concurrent_runner_lock_prevents_double_run
test_unauthenticated_check_is_rejected_without_execution
test_leading_dangling_check_does_not_hide_valid_due_check
test_merged_pr_retirement_waits_for_durable_wake
test_rejected_check_append_failure_keeps_cadence_due

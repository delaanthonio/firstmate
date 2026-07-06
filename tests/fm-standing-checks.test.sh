#!/usr/bin/env bash
# Behavior tests for the shared standing check-script runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-standing-checks)

counting_check() {
  local script=$1 count_file=$2 output=${3:-ready}
  cat > "$script" <<SH
#!/usr/bin/env bash
n=\$(( \$(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "$count_file"
printf '%s\n' "$output"
SH
  chmod +x "$script"
}

test_due_check_appends_wake_and_stamps_schedule() {
  local state="$TMP_ROOT/due/state" count rc queue
  mkdir -p "$state"
  count="$state/count"
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
  fm_supervision_run_due_checks "$missing" 300 5 false; rc=$?
  expect_code 1 "$rc" "missing checks should be a no-op"
  assert_absent "$missing/.wake-queue" "missing checks should not create a wake queue"
  cat > "$silent/quiet.check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$silent/quiet.check.sh"
  fm_supervision_run_due_checks "$silent" 300 5 false; rc=$?
  expect_code 1 "$rc" "silent check should not be actionable"
  assert_absent "$silent/.wake-queue" "silent check should not queue a wake"
  assert_present "$silent/.last-check" "silent due sweep should still stamp .last-check"
  pass "fm_supervision_run_due_checks: missing and silent checks stay quiet"
}

test_erroring_check_fails_open_and_logs_when_requested() {
  local state="$TMP_ROOT/error/state" out rc
  mkdir -p "$state"
  cat > "$state/fail.check.sh" <<'SH'
#!/usr/bin/env bash
echo "bad credentials" >&2
exit 7
SH
  chmod +x "$state/fail.check.sh"
  out=$(fm_supervision_run_due_checks "$state" 300 5 true 2>&1); rc=$?
  expect_code 1 "$rc" "erroring check should fail open"
  assert_contains "$out" "failed open" "erroring check should log fail-open context"
  assert_absent "$state/.wake-queue" "erroring check should not queue a wake"
  pass "fm_supervision_run_due_checks: erroring check fails open"
}

test_timeout_check_fails_open_and_stamps_schedule() {
  local state="$TMP_ROOT/timeout/state" start elapsed out rc
  mkdir -p "$state"
  cat > "$state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
sleep 5
printf 'late\n'
SH
  chmod +x "$state/slow.check.sh"
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
  local state="$TMP_ROOT/locked/state" count rc
  mkdir -p "$state"
  count="$state/count"
  counting_check "$state/task.check.sh" "$count" "ready"
  fm_lock_try_acquire "$state/.last-check.lock" || fail "test should acquire check lock"
  fm_supervision_run_due_checks "$state" 300 5 false; rc=$?
  fm_lock_release "$state/.last-check.lock"
  expect_code 1 "$rc" "held check lock should make runner skip"
  assert_absent "$count" "held check lock should prevent the check from running"
  pass "fm_supervision_run_due_checks: held lock prevents concurrent check execution"
}

test_due_check_appends_wake_and_stamps_schedule
test_not_due_check_does_not_run_again
test_missing_and_silent_checks_do_not_queue
test_erroring_check_fails_open_and_logs_when_requested
test_timeout_check_fails_open_and_stamps_schedule
test_concurrent_runner_lock_prevents_double_run

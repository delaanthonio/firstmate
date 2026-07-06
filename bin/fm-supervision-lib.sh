# shellcheck shell=bash
# Shared supervision predicates and standing-check runner.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# fm_supervision_is_primary_checkout <root> <state-dir>
# True only for the primary firstmate checkout. False in secondmate homes, linked
# crewmate/scout worktrees, unrelated dirs, or homes without an active state dir.
fm_supervision_is_primary_checkout() {
  local root=$1 state=$2 git_dir git_common_dir
  [ -f "$root/.fm-secondmate-home" ] && return 1
  git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common_dir" ] || return 1
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

fm_supervision_path_age() {
  local path=$1 m
  m=$(fm_sup_stat_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_supervision_run_check_script() {  # <script> <timeout-seconds> <stdout-file> <stderr-file>
  local script=$1 timeout_s=$2 out_file=$3 err_file=$4 status
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" bash "$script" >"$out_file" 2>"$err_file"
    status=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" bash "$script" >"$out_file" 2>"$err_file"
    status=$?
  else
    # shellcheck disable=SC2016 # Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_s" bash "$script" >"$out_file" 2>"$err_file"
    status=$?
  fi
  # shellcheck disable=SC2034 # Read by fm_supervision_run_due_checks.
  FM_SUP_CHECK_STATUS=$status
}

fm_supervision_log_check_failure() {  # <script> <status> <stderr-file>
  local script=$1 status=$2 err_file=$3 first_err
  first_err=$(sed -n '1p' "$err_file" 2>/dev/null || true)
  if [ "$status" -eq 124 ]; then
    printf 'fm-turnend-guard: check timed out after FM_CHECK_TIMEOUT: %s\n' "$script" >&2
  elif [ -n "$first_err" ]; then
    printf 'fm-turnend-guard: check failed open: %s exited %s: %s\n' "$script" "$status" "$first_err" >&2
  else
    printf 'fm-turnend-guard: check failed open: %s exited %s\n' "$script" "$status" >&2
  fi
}

# fm_supervision_run_due_checks <state-dir> <interval-seconds> <timeout-seconds> [log-errors]
# Scans state/*.check.sh only when the shared .last-check cadence says the sweep
# is due. A lock around the due recheck and run prevents the Stop hook and
# watcher from running the same checks concurrently or back-to-back. On the first
# actionable stdout line, appends the wake to state/.wake-queue exactly as the
# watcher does, stamps .last-check, and returns 0 with:
#   FM_SUP_CHECK_REASON    "check: <script>: <output>"
#   FM_SUP_CHECK_SCRIPT    script path
#   FM_SUP_CHECK_OUTPUT    script stdout
# Returns 1 for no check, no due sweep, silent checks, check failure/timeout, or
# a concurrent runner holding the lock. Returns 2 if the durable wake append
# fails. Requires fm-wake-lib.sh to be sourced by the caller for lock and queue
# primitives.
fm_supervision_run_due_checks() {
  local state=$1 interval=$2 timeout_s=$3 log_errors=${4:-false}
  local last_check="$state/.last-check" lock="$state/.last-check.lock" c out err_file out_file
  local old_queue=${FM_WAKE_QUEUE-} old_queue_lock=${FM_WAKE_QUEUE_LOCK-} had_queue=0 had_queue_lock=0 append_rc
  FM_SUP_CHECK_REASON=
  FM_SUP_CHECK_SCRIPT=
  FM_SUP_CHECK_OUTPUT=
  FM_SUP_CHECK_STATUS=0

  for c in "$state"/*.check.sh; do
    [ -e "$c" ] || return 1
    break
  done

  [ "$(fm_supervision_path_age "$last_check")" -ge "$interval" ] || return 1
  if ! fm_lock_try_acquire "$lock"; then
    return 1
  fi

  if [ "$(fm_supervision_path_age "$last_check")" -lt "$interval" ]; then
    fm_lock_release "$lock"
    return 1
  fi

  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-check-stderr.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-check-stdout.XXXXXX") || {
    rm -f "$err_file"
    fm_lock_release "$lock"
    return 1
  }
  for c in "$state"/*.check.sh; do
    [ -e "$c" ] || continue
    : > "$err_file"
    : > "$out_file"
    fm_supervision_run_check_script "$c" "$timeout_s" "$out_file" "$err_file"
    out=$(cat "$out_file" 2>/dev/null || true)
    if [ -n "$out" ]; then
      # shellcheck disable=SC2034 # Read by callers after this function returns 0.
      FM_SUP_CHECK_SCRIPT=$c
      # shellcheck disable=SC2034 # Read by callers after this function returns 0.
      FM_SUP_CHECK_OUTPUT=$out
      FM_SUP_CHECK_REASON="check: $c: $out"
      [ "${FM_WAKE_QUEUE+x}" ] && had_queue=1
      [ "${FM_WAKE_QUEUE_LOCK+x}" ] && had_queue_lock=1
      FM_WAKE_QUEUE="$state/.wake-queue"
      FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
      fm_wake_append check "$c" "$FM_SUP_CHECK_REASON"
      append_rc=$?
      if [ "$had_queue" -eq 1 ]; then FM_WAKE_QUEUE=$old_queue; else unset FM_WAKE_QUEUE; fi
      if [ "$had_queue_lock" -eq 1 ]; then FM_WAKE_QUEUE_LOCK=$old_queue_lock; else unset FM_WAKE_QUEUE_LOCK; fi
      rm -f "$err_file" "$out_file"
      touch "$last_check"
      fm_lock_release "$lock"
      [ "$append_rc" -eq 0 ] || return 2
      return 0
    fi
    if [ "$FM_SUP_CHECK_STATUS" -ne 0 ] && [ "$log_errors" = true ]; then
      fm_supervision_log_check_failure "$c" "$FM_SUP_CHECK_STATUS" "$err_file"
    fi
  done

  rm -f "$err_file" "$out_file"
  touch "$last_check"
  fm_lock_release "$lock"
  return 1
}

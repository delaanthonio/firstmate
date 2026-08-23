# shellcheck shell=bash
# Shared supervision predicates and turn-end standing-check backstop.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

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
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

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

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

fm_supervision_path_age() {
  local path=$1 m
  m=$(fm_sup_stat_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_supervision_run_check_script() {  # <label> <timeout-seconds> <stdout-file> <stderr-file> <command...>
  local _label=$1 timeout_s=$2 out_file=$3 err_file=$4 status
  shift 4
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" "$@" >"$out_file" 2>"$err_file"
    status=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" "$@" >"$out_file" 2>"$err_file"
    status=$?
  else
    # shellcheck disable=SC2016 # Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_s" "$@" >"$out_file" 2>"$err_file"
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
# watcher from running the same checks concurrently or back-to-back. Checks use
# the same authenticated shapes as the watcher: the byte-static X shim dispatches
# the tracked poller, PR polls use their validated registration snapshot, and a
# custom check runs only from its registered immutable snapshot. On the first
# actionable stdout line (or an authentication rejection), appends the wake to
# state/.wake-queue, stamps .last-check, and returns 0 with:
#   FM_SUP_CHECK_REASON    "check: <script>: <output>"
#   FM_SUP_CHECK_SCRIPT    script path
#   FM_SUP_CHECK_OUTPUT    script stdout
# Returns 1 for no check, no due sweep, silent checks, check failure/timeout, or
# a concurrent runner holding the lock. Returns 2 if the durable wake append
# fails. Requires fm-wake-lib.sh, fm-x-lib.sh, fm-pr-lib.sh, and fm-check-lib.sh
# to be sourced by the caller.
fm_supervision_run_due_checks() {
  local state=$1 interval=$2 timeout_s=$3 log_errors=${4:-false}
  local last_check="$state/.last-check" lock="$state/.last-check.lock" c out err_file out_file
  local root=${FM_ROOT:-} home=${FM_HOME:-} id is_pr_poll provider url host path number custom_snapshot
  local rejected_checks= matched_check=0
  local old_queue=${FM_WAKE_QUEUE-} old_queue_lock=${FM_WAKE_QUEUE_LOCK-} had_queue=0 had_queue_lock=0 append_rc
  FM_SUP_CHECK_REASON=
  FM_SUP_CHECK_SCRIPT=
  FM_SUP_CHECK_OUTPUT=
  FM_SUP_CHECK_STATUS=0

  for c in "$state"/*.check.sh; do
    if [ -e "$c" ] || [ -L "$c" ]; then
      matched_check=1
    fi
    break
  done
  [ "$matched_check" -eq 1 ] || return 1

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
    if [ ! -e "$c" ]; then
      [ -L "$c" ] && rejected_checks="$rejected_checks $c"
      continue
    fi
    : > "$err_file"
    : > "$out_file"
    is_pr_poll=0
    custom_snapshot=
    if [ "$(basename "$c")" = x-watch.check.sh ]; then
      if [ -n "$root" ] && [ -n "$home" ] \
        && fmx_poll_shim_valid "$c" "$home" "$root" \
        && [ -f "$root/bin/fm-x-poll.sh" ] && [ ! -L "$root/bin/fm-x-poll.sh" ]; then
        fm_supervision_run_check_script "$c" "$timeout_s" "$out_file" "$err_file" \
          env FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
          FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$home/config}" \
          bash "$root/bin/fm-x-poll.sh"
      else
        rejected_checks="$rejected_checks $c"
        continue
      fi
    else
      id=$(basename "$c" .check.sh)
      if [ -n "$root" ] && fm_pr_poll_snapshot_capture "$state" "$id" "$root/bin/fm-pr-poll.sh"; then
        is_pr_poll=1
        provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
        url=$FM_PR_POLL_SNAPSHOT_URL
        host=$FM_PR_POLL_SNAPSHOT_HOST
        path=$FM_PR_POLL_SNAPSHOT_PATH
        number=$FM_PR_POLL_SNAPSHOT_NUMBER
        fm_supervision_run_check_script "$c" "$timeout_s" "$out_file" "$err_file" \
          bash "$root/bin/fm-pr-poll.sh" --validated "$provider" "$url" "$host" "$path" "$number"
      elif fm_custom_check_snapshot_prepare "$state" "$id"; then
        custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
        fm_supervision_run_check_script "$c" "$timeout_s" "$out_file" "$err_file" bash "$custom_snapshot"
      else
        fm_custom_check_snapshot_cleanup
        rejected_checks="$rejected_checks $c"
        continue
      fi
    fi
    out=$(cat "$out_file" 2>/dev/null || true)
    if [ -n "$out" ]; then
      # shellcheck disable=SC2034 # Read by callers after this function returns 0.
      FM_SUP_CHECK_SCRIPT=$c
      # shellcheck disable=SC2034 # Read by callers after this function returns 0.
      FM_SUP_CHECK_OUTPUT=$out
      if [ -n "$rejected_checks" ]; then
        FM_SUP_CHECK_OUTPUT="$FM_SUP_CHECK_OUTPUT
rejected unauthenticated state checks:$rejected_checks"
      fi
      FM_SUP_CHECK_REASON="check: $c: $FM_SUP_CHECK_OUTPUT"
      fm_custom_check_snapshot_cleanup
      [ "${FM_WAKE_QUEUE+x}" ] && had_queue=1
      [ "${FM_WAKE_QUEUE_LOCK+x}" ] && had_queue_lock=1
      FM_WAKE_QUEUE="$state/.wake-queue"
      FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
      fm_wake_append check "$c" "$FM_SUP_CHECK_REASON"
      append_rc=$?
      if [ "$had_queue" -eq 1 ]; then FM_WAKE_QUEUE=$old_queue; else unset FM_WAKE_QUEUE; fi
      if [ "$had_queue_lock" -eq 1 ]; then FM_WAKE_QUEUE_LOCK=$old_queue_lock; else unset FM_WAKE_QUEUE_LOCK; fi
      if [ "$append_rc" -eq 0 ] && [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
        if fm_pr_poll_retirement_publish "$state" "$id" "$root/bin/fm-pr-poll.sh" "$out"; then
          fm_pr_poll_retirement_recover_one "$state" "$id" "$root/bin/fm-pr-poll.sh" || true
        fi
      fi
      rm -f "$err_file" "$out_file"
      [ "$append_rc" -ne 0 ] || touch "$last_check"
      fm_lock_release "$lock"
      [ "$append_rc" -eq 0 ] || return 2
      return 0
    fi
    if [ "$FM_SUP_CHECK_STATUS" -ne 0 ] && [ "$log_errors" = true ]; then
      fm_supervision_log_check_failure "$c" "$FM_SUP_CHECK_STATUS" "$err_file"
    fi
    fm_custom_check_snapshot_cleanup
  done

  if [ -n "$rejected_checks" ]; then
    # shellcheck disable=SC2034 # Read by callers after this function returns 0.
    FM_SUP_CHECK_SCRIPT=unauthenticated-state-checks
    FM_SUP_CHECK_OUTPUT="rejected unauthenticated state checks:$rejected_checks"
    FM_SUP_CHECK_REASON="check: $FM_SUP_CHECK_OUTPUT"
    [ "${FM_WAKE_QUEUE+x}" ] && had_queue=1
    [ "${FM_WAKE_QUEUE_LOCK+x}" ] && had_queue_lock=1
    FM_WAKE_QUEUE="$state/.wake-queue"
    FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
    fm_wake_append check unauthenticated-state-checks "$FM_SUP_CHECK_REASON"
    append_rc=$?
    if [ "$had_queue" -eq 1 ]; then FM_WAKE_QUEUE=$old_queue; else unset FM_WAKE_QUEUE; fi
    if [ "$had_queue_lock" -eq 1 ]; then FM_WAKE_QUEUE_LOCK=$old_queue_lock; else unset FM_WAKE_QUEUE_LOCK; fi
    rm -f "$err_file" "$out_file"
    [ "$append_rc" -ne 0 ] || touch "$last_check"
    fm_lock_release "$lock"
    [ "$append_rc" -eq 0 ] || return 2
    return 0
  fi

  rm -f "$err_file" "$out_file"
  touch "$last_check"
  fm_lock_release "$lock"
  return 1
}

#!/usr/bin/env bash
# Claude Code "Stop" hook for the firstmate PRIMARY session only.
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# re-arming the watcher, and then never runs another fleet-touching command
# itself, can sit blind for hours - see docs/turnend-guard.md for the 2026-07-04
# incident this backstops (a parked no-mistakes gate sat unwatched all night).
# This hook is push-based: Claude Code invokes it every time the primary is
# about to end a turn, and it can force the turn to continue instead by exiting
# 2 with a reason on stderr. That mechanism, the stdin payload schema, and the
# stop_hook_active loop-guard field are all verified empirically - see
# docs/turnend-guard.md.
# The tracked settings command invokes this script as
# "$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh because Claude Code runs hook
# commands via /bin/sh from the session's current cwd, not necessarily the repo
# root.
#
# Ships as the TRACKED .claude/settings.json at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, any
# crewmate/scout task worktree spawned to work on firstmate itself (the
# recursive "firstmate improving itself" case), and every secondmate home
# (treehouse-leased or git-cloned). It must therefore scope itself to the
# PRIMARY at runtime and stay a silent, fast no-op everywhere else.
#
# Loop-guard: never block twice in the same turn. Claude Code's stdin payload
# carries stop_hook_active=true when the CURRENT stop attempt was itself already
# forced by an earlier block this turn; on that signal we always allow the stop,
# whether or not the watcher actually got re-armed. That bounds this to at most
# one forced continuation per turn - never a wedged, un-endable session - while
# still nagging again on a later turn if the problem persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Read the whole Stop hook payload once; never block on unreadable/absent stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# --- scope precisely to the PRIMARY checkout --------------------------------
fm_supervision_is_primary_checkout "$FM_ROOT" "$STATE" || exit 0

# --- standing check-script backstop -----------------------------------------
if fm_supervision_run_due_checks "$STATE" "$CHECK_INTERVAL" "$CHECK_TIMEOUT" true; then
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END WITH A DUE CHECK WAKE\n'
    printf '●  %s\n' "$FM_SUP_CHECK_SCRIPT"
    printf '●  %s\n' "$FM_SUP_CHECK_OUTPUT"
    printf '●  Drain queued wakes before ending the turn: bin/fm-wake-drain.sh\n'
    printf '●%s\n' "$rule"
  } >&2
  exit 2
else
  check_rc=$?
  [ "$check_rc" -eq 2 ] && printf 'fm-turnend-guard: failed to queue due check wake; allowing stop fail-open\n' >&2
fi

# --- the actual predicate ----------------------------------------------------
fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && exit 0

REASON='tasks in flight, no live watcher - run bin/fm-watch-arm.sh as a background task before ending the turn'
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2

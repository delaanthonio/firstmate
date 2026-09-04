#!/usr/bin/env bash
# Droid PreToolUse guard for interactive approval questions during away mode.
#
# `.factory/settings.json` invokes this command only for Droid's exact AskUser
# tool.  While the durable away flag exists, the call is denied rather than
# answered: the question remains with the keyed status or captain-decision
# owner that raised it, and Droid is told to continue independently authorized
# work.  Removing the flag through bin/fm-afk-return.sh restores AskUser with no
# saved answer or widened authority.
#
# The guard is deliberately Droid-only.  It creates no question queue, parses
# no question prose, and changes no other harness integration.  It is inert in
# linked task worktrees and non-Firstmate repositories through the shared
# primary-scope predicate.
#
# Usage:
#   <Droid AskUser PreToolUse JSON on stdin> | fm-droid-afk-askuser-check.sh
#
# Exit/output contract:
#   ALLOW - exit 0 and no output when AFK is inactive or scope is not a primary.
#   DENY  - exit 2, stdout empty, and a Droid-compatible deny object on stderr.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -e "$STATE/.afk" ] || exit 0

REASON='[afk-approval-deferral] away mode is active. This AskUser call is denied, not answered. Do not retry it or ask the captain in plain text while state/.afk exists. Leave the approval source unresolved under its existing durable decision key and evidence, continue every independently authorized action, and present the outstanding question only after a real unmarked captain message has completed bin/fm-afk-return.sh. An operationally prefixed input is not the captain returning, and away mode grants no additional approval, merge, destructive, irreversible, or security authority.'

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2

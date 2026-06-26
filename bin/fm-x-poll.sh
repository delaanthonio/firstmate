#!/usr/bin/env bash
# One short-poll of the relay connector for a pending X mention.
#
# Inert by default: a HARD no-op (exit 0, no output) unless X mode is configured
# via a non-empty FMX_PAIRING_TOKEN (from the home's .env or the environment).
# This script is the body of the watcher check shim state/x-watch.check.sh, where
# the contract is "output => wake firstmate, silence => keep sleeping", so the
# no-op keeps the watcher behaving exactly as today until a user opts in.
#
# Behavior when X mode is on:
#   HTTP 204 / empty / any non-question response -> print nothing, exit 0 (no wake)
#   a question JSON                              -> stash the full object to
#       state/x-inbox/<request_id>.json and print one compact line
#       "x-mention <request_id>" (which becomes the watcher's check: wake payload)
#
# Config (home .env or env): FMX_PAIRING_TOKEN (required), FMX_RELAY_URL
# (default https://myfirstmate.io). Auth: Authorization: Bearer <token>.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

fmx_load_config
# Hard no-op when X mode is off: this is what keeps the check shim inert.
[ -n "$FMX_TOKEN" ] || exit 0

# Without curl/jq we cannot poll or parse; stay silent (no spurious wake).
command -v curl >/dev/null 2>&1 || { echo "fm-x-poll: curl not found" >&2; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "fm-x-poll: jq not found"   >&2; exit 0; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-x-poll.XXXXXX") || exit 0
trap 'rm -f "$BODY_FILE"' EXIT

# Short, bounded poll: a failure or timeout simply means "no wake this cycle";
# the next check cycle retries. -m 5 keeps this well inside the watcher's
# per-check timeout so the supervision loop is never starved.
code=$(curl -m 5 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H "Authorization: Bearer $FMX_TOKEN" \
  -H 'Accept: application/json' \
  "$FMX_RELAY/connector/poll" 2>/dev/null) || exit 0

# 204 (nothing pending) is the common path; only 200 can carry a question.
[ "$code" = "200" ] || exit 0
[ -s "$BODY_FILE" ] || exit 0

REQ=$(jq -r '.request_id // empty' "$BODY_FILE" 2>/dev/null) || exit 0
[ -n "$REQ" ] || exit 0

# A pending mention is only actionable with an actual question: require a
# non-empty .text. An empty/absent/null question must not stash an inbox file or
# wake fmx-respond (a public reply flow) for nothing - stay inert (exit 0).
TEXT=$(jq -r '.text // empty' "$BODY_FILE" 2>/dev/null) || exit 0
[ -n "$TEXT" ] || exit 0

# Defend the inbox filename: request_id is relay-issued (e.g. "req-7"), but never
# trust it into a path. Reject anything outside a safe slug.
case "$REQ" in
  ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

INBOX="$STATE/x-inbox"
mkdir -p "$INBOX" || exit 0
# Stash the full question object atomically so a concurrent reader never sees a
# half-written file.
if jq '.' "$BODY_FILE" > "$INBOX/$REQ.json.tmp" 2>/dev/null; then
  mv -f "$INBOX/$REQ.json.tmp" "$INBOX/$REQ.json"
else
  rm -f "$INBOX/$REQ.json.tmp"
  exit 0
fi

printf 'x-mention %s\n' "$REQ"

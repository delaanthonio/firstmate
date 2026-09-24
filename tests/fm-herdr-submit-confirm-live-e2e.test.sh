#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It fails naming the harness and version rather than degrading
# quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude node

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
CLAUDE_CONFIG_ROOT="$TMP_ROOT/claude-config"
mkdir -p "$FAKEBIN" "$CLAUDE_CONFIG_ROOT"
CHECKED=0

# Keep workspace trust inside the disposable lab. Copy the operator's existing
# non-secret account/config metadata when present, then add only this worktree's
# trust bit to the copy. The real Claude process below consumes this store, so a
# missing or ineffective registration still fails at the rendered surface.
AMBIENT_CLAUDE_STORE="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
LAB_CLAUDE_STORE="$CLAUDE_CONFIG_ROOT/.claude.json"
if [ -f "$AMBIENT_CLAUDE_STORE" ]; then
  cp "$AMBIENT_CLAUDE_STORE" "$LAB_CLAUDE_STORE" || fail "could not seed the isolated Claude config"
fi
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  AMBIENT_CLAUDE_CREDENTIALS="$CLAUDE_CONFIG_DIR/.credentials.json"
else
  AMBIENT_CLAUDE_CREDENTIALS="$HOME/.claude/.credentials.json"
fi
if [ -f "$AMBIENT_CLAUDE_CREDENTIALS" ]; then
  cp "$AMBIENT_CLAUDE_CREDENTIALS" "$CLAUDE_CONFIG_ROOT/.credentials.json" \
    || fail "could not seed isolated Claude credentials"
  chmod 600 "$CLAUDE_CONFIG_ROOT/.credentials.json"
fi
node - "$LAB_CLAUDE_STORE" "$ROOT" <<'NODE' || fail "could not register isolated Claude workspace trust"
const fs = require("node:fs");
const [store, project] = process.argv.slice(2);
let root = {};
try {
  root = JSON.parse(fs.readFileSync(store, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
if (!root.projects || typeof root.projects !== "object" || Array.isArray(root.projects)) {
  root.projects = {};
}
const entry = root.projects[project];
root.projects[project] = {
  ...(entry && typeof entry === "object" && !Array.isArray(entry) ? entry : {}),
  hasTrustDialogAccepted: true,
};
fs.writeFileSync(store, `${JSON.stringify(root)}\n`, { mode: 0o600 });
NODE

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# Keep Claude's real prompt-suggestion default. This live guard used to force
# suggestions off, masking the idle rendering that the away-mode injector must
# classify in production.
herdr_wait_for_shell_ready "$SESSION" "$PANE" \
  || fail "the Claude pane's shell did not become ready"
lab pane run "$PANE" "CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_ROOT' CLAUDE_CODE_SEND_FEEDBACK=0 claude --permission-mode auto --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
if [ "$idle" != 1 ]; then
  lab pane read "$PANE" --source recent --lines 200 2>/dev/null | tail -40 | sed 's/^/    /' >&2
  fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"
fi

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$landed" != 1 ]; then
  printf '%s\n' "$screen" | tail -40 | sed 's/^/    /' >&2
  fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
fi
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"

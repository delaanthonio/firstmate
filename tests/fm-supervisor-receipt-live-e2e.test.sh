#!/usr/bin/env bash
# Opt-in real Droid receiving-conversation receipt over the production tmux
# daemon path. The Herdr fleet tripwire is provisioned/retired only by its helper;
# tmux uses the lab-home helper's short private directory. No real alerts fire.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_SUPERVISOR_RECEIPT_LIVE droid tmux herdr jq

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-supervisor-handshake-u1)
LAB_ROOT=${FM_RECEIPT_LIVE_EVIDENCE:-$(fm_test_tmproot fm-receipt-live)}
FM_HOME="$LAB_ROOT/home"
LAB_TMUX_DIR=
provisioned=0
# shellcheck disable=SC2329 # EXIT owns combined cleanup, including tripwire.
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" tmux kill-server 2>/dev/null || true
    "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  fi
  if [ "$provisioned" = 1 ]; then "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1; fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'isolated Herdr tripwire provisioning failed'
provisioned=1
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null || fail 'lab home creation failed'
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME") || fail 'private tmux directory failed'
export FM_HOME TMUX_TMPDIR="$LAB_TMUX_DIR" FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
export FM_WEDGE_ALARM_EXEC=discard FM_TEST_SEAM=1 FM_TEST_HARNESS=droid FM_DAEMON_PRIMARY_HARNESS=droid
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_ESCALATE_BATCH_SECS=0 FM_SUPERVISOR_ACK_SECS=240 FM_SUPERVISOR_RETRY_SECS=5
PROJECT="$LAB_ROOT/project"
mkdir -p "$PROJECT/.factory"
ln -s "$ROOT/bin" "$PROJECT/bin"
cat > "$PROJECT/AGENTS.md" <<'INSTRUCTIONS'
This is an isolated receiving-conversation acceptance fixture.
Complete the requested startup command exactly, then finish that turn.
For every later FIRSTMATE_OP away-supervisor input, read it, leave any fixture decision parked in durable state, execute its ack-supervisor command through Execute in this conversation, then finish the turn.
Do not exit away mode or resolve the fixture decision.
Do not start a watcher, modify source code, or send a notification.
INSTRUCTIONS
printf '{"hooks":{}}\n' > "$PROJECT/.factory/settings.json"
export FM_ROOT_OVERRIDE="$PROJECT"
# Source only the existing delivery guards. This does not start another owner.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

cat > "$PROJECT/startup.sh" <<'STARTUP'
#!/usr/bin/env bash
set -e
bash bin/fm-lock.sh
touch startup-busy
attempt=0
while [ ! -f startup-release ] && [ "$attempt" -lt 90 ]; do
  sleep 1
  attempt=$((attempt + 1))
done
[ -f startup-release ]
touch startup-ended
STARTUP
# Observe every daemon literal send without changing or refusing any send.
# The explicit command barrier bounds a positive initiating-unsafe interval.
REAL_TMUX=$(command -v tmux)
mkdir -p "$LAB_ROOT/tools"
{
  printf '#!/usr/bin/env bash\n'
  printf 'real_tmux=%q\nproject=%q\nobservations=%q\n' "$REAL_TMUX" "$PROJECT" "$LAB_ROOT/probe-typing.tsv"
  cat <<'OBSERVER'
if [ "${1:-}" = send-keys ]; then
  for arg in "$@"; do
    case "$arg" in
      *FIRSTMATE_OP:*|*'Firstmate operational input waiting:'*)
        interval=before-end
        [ ! -f "$project/startup-ended" ] || interval=after-end
        printf '%s\t%s\n' "$(date +%s)" "$interval" >> "$observations" ;;
    esac
  done
fi
exec "$real_tmux" "$@"
OBSERVER
} > "$LAB_ROOT/tools/tmux"
chmod +x "$LAB_ROOT/tools/tmux"
# tmux's new shell may reset PATH. The supported launch-entry seam preserves
# only this observer in the real daemon entry, without replacing any guard.
{
  printf '#!/usr/bin/env bash\n'
  printf 'export PATH=%q\nexec %q\n' "$LAB_ROOT/tools:$PATH" "$ROOT/bin/fm-afk-start.sh"
} > "$LAB_ROOT/daemon-entry"
chmod +x "$LAB_ROOT/daemon-entry"
export FM_AFK_LAUNCH_ENTRY="$LAB_ROOT/daemon-entry"
prompt='Use Execute to run exactly: bash startup.sh. Then reply RECEIPT_STARTUP_FINISHED and finish the turn.'
printf -v launch 'cd %q && exec droid --auto high %q' "$PROJECT" "$prompt"
tmux new-session -d -s receipt-primary -x 180 -y 50 "$launch" || fail 'Droid launch failed'
FM_SUPERVISOR_BACKEND=tmux
FM_SUPERVISOR_TARGET=$(tmux display-message -p -t receipt-primary '#{pane_id}')
export FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET
trust=0
for _ in $(seq 1 240); do
  capture=$(tmux capture-pane -p -t "$FM_SUPERVISOR_TARGET" -S -150)
  if [ "$trust" = 0 ] && printf '%s' "$capture" | grep -q 'Trust this folder?'; then
    tmux send-keys -t "$FM_SUPERVISOR_TARGET" Enter
    trust=1
  fi
  [ ! -f "$PROJECT/startup-busy" ] || break
  sleep 0.25
done
[ -f "$PROJECT/startup-busy" ] || { printf '%s\n' "$capture" > "$LAB_ROOT/startup-failure.txt"; fail 'real Droid did not acquire the isolated session lock'; }
pane_is_busy "$FM_SUPERVISOR_TARGET" tmux || fail 'real initiating turn was not observably busy'
tmux capture-pane -ep -t "$FM_SUPERVISOR_TARGET" > "$LAB_ROOT/unsafe-screen.txt"
printf 'busy=true\ncomposer=%s\n' "$(fm_backend_composer_state tmux "$FM_SUPERVISOR_TARGET")" > "$LAB_ROOT/unsafe-observation.txt"
"$ROOT/bin/fm-afk-launch.sh" enter --words 'isolated receipt verification' > "$LAB_ROOT/entry.txt" || fail 'entry failed'
"$ROOT/bin/fm-afk-launch.sh" start > "$LAB_ROOT/launch.txt" 2>&1 || fail 'daemon launch failed'
"$ROOT/bin/fm-operational-input.sh" coverage | tee "$LAB_ROOT/initial-coverage.txt"
grep -q 'coverage pending' "$LAB_ROOT/initial-coverage.txt" || fail 'busy initiating turn was certified'
# Require an actual pending challenge attempt during the unsafe command turn.
for _ in $(seq 1 160); do
  if [ -f "$FM_HOME/state/.supervisor-receipt.json" ] \
    && jq -e '.phase == "pending" and .pending.attempts > 0 and (.pending.acked | not)' "$FM_HOME/state/.supervisor-receipt.json" >/dev/null; then break; fi
  sleep .1
done
[ ! -f "$PROJECT/startup-ended" ] || fail 'initiating unsafe interval ended before observation'
cp "$FM_HOME/state/.supervisor-receipt.json" "$LAB_ROOT/unsafe-receipt.json"
jq -e '.phase == "pending" and .pending.attempts > 0 and (.pending.acked | not)' "$LAB_ROOT/unsafe-receipt.json" >/dev/null \
  || fail 'no positive challenge attempt during initiating unsafe interval'
[ ! -s "$LAB_ROOT/probe-typing.tsv" ] || fail 'probe typed during initiating unsafe command turn'
touch "$PROJECT/startup-release"
for _ in $(seq 1 960); do
  if [ -f "$FM_HOME/state/.supervisor-receipt.json" ] \
    && jq -e '.phase == "verified" and .pending.kind == "probe" and .pending.acked' "$FM_HOME/state/.supervisor-receipt.json" >/dev/null; then break; fi
  sleep 0.25
done
cp "$FM_HOME/state/.supervisor-receipt.json" "$LAB_ROOT/handoff.json"
"$ROOT/bin/fm-operational-input.sh" coverage | tee "$LAB_ROOT/handoff-coverage.txt"
grep -q 'coverage verified' "$LAB_ROOT/handoff-coverage.txt" || {
  tmux capture-pane -p -t "$FM_SUPERVISOR_TARGET" -S -300 > "$LAB_ROOT/receiver-failure.txt"
  fail 'real receiving conversation never acknowledged; fixture success is not live proof'
}
[ -f "$PROJECT/startup-ended" ] || fail 'receiver consumed before initiating command completed'
[ -s "$LAB_ROOT/probe-typing.tsv" ] || fail 'no real guarded probe typing recorded'
! grep -q before-end "$LAB_ROOT/probe-typing.tsv" || fail 'probe typed during observed unsafe interval'
tmux capture-pane -ep -t "$FM_SUPERVISOR_TARGET" > "$LAB_ROOT/handoff-screen.txt"
pass 'real Droid finishes its busy entry turn, then consumes and acknowledges the guarded handoff probe'

printf 'task_id=receipt-fixture\nbackend=tmux\nwindow=receipt-primary\nharness=droid\n' > "$FM_HOME/state/receipt-fixture.meta"
printf 'needs-decision [at=%s] [key=receipt-fixture]: isolated receipt fixture; keep this decision parked\n' "$(date +%s)" > "$FM_HOME/state/receipt-fixture.status"
for _ in $(seq 1 960); do
  if jq -e '.phase == "verified" and .pending.kind == "work" and .pending.acked and .pending.retired' "$FM_HOME/state/.supervisor-receipt.json" >/dev/null; then break; fi
  sleep 0.25
done
cp "$FM_HOME/state/.supervisor-receipt.json" "$LAB_ROOT/work.json"
jq -e '.phase == "verified" and .pending.kind == "work" and .pending.acked and .pending.retired' "$LAB_ROOT/work.json" >/dev/null \
  || fail 'real actionable delivery was not acknowledged and retired'
tmux capture-pane -p -t "$FM_SUPERVISOR_TARGET" -S -300 > "$LAB_ROOT/receiver.txt"
[ ! -s "$FM_HOME/state/.subsuper-escalations" ] || fail 'consumed snapshot was not retired'
if ! "$ROOT/bin/fm-afk-launch.sh" stop > "$LAB_ROOT/stop.txt" 2>&1; then
  cp "$FM_HOME/state/.supervise-daemon.log" "$LAB_ROOT/stop-daemon.log" 2>/dev/null || true
  cp "$FM_HOME/state/.supervisor-receipt.json" "$LAB_ROOT/stop-receipt.json" 2>/dev/null || true
  { ls -ld "$FM_HOME/state/.supervisor-receipt.lock"; cat "$FM_HOME/state/.supervisor-receipt.lock/pid"; } > "$LAB_ROOT/stop-lock.txt" 2>&1
  cat "$LAB_ROOT/stop.txt" >&2
  fail 'isolated stop failed (receipt, daemon, and lock evidence retained)'
fi
"$ROOT/bin/fm-operational-input.sh" coverage | tee "$LAB_ROOT/return-coverage.txt"
grep -q 'coverage inactive' "$LAB_ROOT/return-coverage.txt" || fail 'return retained verified coverage'
token=$(jq -r .pending.token "$LAB_ROOT/work.json")
! "$ROOT/bin/fm-operational-input.sh" ack-supervisor "$token" > "$LAB_ROOT/obsolete-ack.txt" 2>&1 \
  || fail 'return accepted obsolete challenge'
pass 'real actionable-message acknowledgment retires its buffer, and return invalidates coverage'
printf 'Droid %s; tmux %s\n' "$(droid --version)" "$(tmux -V)"

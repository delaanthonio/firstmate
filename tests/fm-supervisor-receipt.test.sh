#!/usr/bin/env bash
# Deterministic receipt state-machine and guarded daemon delivery regressions.
# Transport/session fixtures prove the contract, not live harness consumption.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-receipt)

setup() {
  FM_HOME="$TMP_ROOT/$1"
  state="$FM_HOME/state"
  mkdir -p "$state" "$FM_HOME/config"
  touch "$state/.afk"
  FM_STATE_OVERRIDE=$state
  FM_SUPERVISOR_TARGET='%fixture'
  FM_SUPERVISOR_BACKEND=tmux
  FM_SUPERVISOR_ACK_SECS=60
  FM_SUPERVISOR_RETRY_SECS=10
  FM_SUPERVISOR_IDLE_SECS=120
  FM_WEDGE_ALARM_CHANNEL=command:fixture
  FM_WEDGE_ALARM_LOG="$state/alarms"
  export FM_HOME FM_STATE_OVERRIDE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_WEDGE_ALARM_LOG
  # shellcheck source=bin/fm-afk-start.sh
  . "$ROOT/bin/fm-afk-start.sh"
  set +e
  FM_RECEIPT_ACTIVE=1
  clock=1000; busy=0; composer_verdict=empty; session='fixture-session'
  fm_receipt_now() { printf '%s\n' "$clock"; }
  _now() { fm_receipt_now; }
  fm_supervision_host_main_key() { printf '%s\n' "$session"; }
  fm_receipt_destination() { printf '%s\n' "$2"; }
  fm_backend_target_exists() { return 0; }
  pane_is_busy() { [ "$busy" = 1 ]; }
  fm_backend_composer_state() { printf '%s\n' "$composer_verdict"; }
  fm_daemon_primary_harness() { printf codex; }
  fm_backend_send_text_submit() { printf '%s\n' "$3" >> "$state/submits"; printf empty; }
  fm_receipt_begin "$state" tmux '%fixture' || fail 'receipt begin failed'
}

load_token() { fm_receipt_load "$state" || fail 'receipt unreadable'; token=$(fm_receipt_field .pending.token); }
receiver_ack() {
  # Explicit receiver fixture; real receiver ownership tested separately below.
  fm_receipt_receiver() { return 0; }
  fm_receipt_ack "$state" "$1"
}

(
  setup handoff
  assert_contains "$(fm_receipt_status "$state")" 'coverage pending' 'initial coverage certified itself'
  load_token
  # A native background producer can inherit both the primary ancestry and
  # pane environment. Even positive receiver ownership cannot certify itself.
  fm_session_lock_owned_by_self() { return 0; }
  ! TMUX_PANE=%fixture fm_receipt_ack "$state" "$token" || fail 'producer certified its own receipt'
  busy=1
  fm_daemon_receipt_tick "$state"
  assert_absent "$state/submits" 'initiating busy turn received an injection'
  busy=0; clock=1010
  fm_daemon_receipt_tick "$state"
  assert_contains "$(cat "$state/submits")" "ack-supervisor $token" 'real delivery payload omitted the fresh receiver command'
  assert_contains "$(fm_receipt_status "$state")" 'coverage pending' 'transport certified consumption'
  receiver_ack "$token" || fail 'current receiver ack rejected'
  assert_contains "$(fm_receipt_status "$state")" 'coverage verified' 'receiver ack did not verify'
  clock=1011
  receiver_ack "$token" || fail 'idempotent duplicate ack rejected'
  fm_receipt_load "$state"
  [ "$(fm_receipt_field .last_ack)" = 1010 ] || fail 'duplicate refreshed coverage'
  pass 'pending, busy entry, idle delivery, receiver ack, and idempotent duplicate'
) || exit 1

(
  setup unknown
  composer_verdict=unknown
  fm_daemon_receipt_tick "$state"
  assert_absent "$state/submits" 'unknown composer received an injection'
  clock=1060
  fm_daemon_receipt_tick "$state" || true
  assert_contains "$(fm_receipt_status "$state")" 'coverage unhealthy' 'unknown composer never expired'
  assert_contains "$(cat "$state/alarms")" WEDGED 'expiry did not use independent alarm'
  assert_contains "$(cat "$state/.subsuper-inject-wedged")" 'transport submitted=false' 'alarm falsely claimed submit'
  pass 'unknown composer preserves the guard, expires, and alarms independently'
) || exit 1

(
  setup lost-consumption
  fm_daemon_receipt_tick "$state"
  load_token
  clock=1059
  fm_daemon_receipt_tick "$state"
  clock=1060
  fm_daemon_receipt_tick "$state" || true
  ! receiver_ack "$token" || fail 'expired receiver ack accepted'
  assert_contains "$(cat "$state/.subsuper-inject-wedged")" 'transport submitted=true' 'alarm lost honest transport evidence'
  assert_contains "$(fm_receipt_status "$state")" 'coverage unhealthy' 'submit without consumption remained healthy'
  pass 'accepted submit without consumption expires and rejects late ack'
) || exit 1

(
  setup work
  load_token; receiver_ack "$token" || fail 'handoff ack failed'
  fm_daemon_receipt_tick "$state"
  printf 'actionable one\n' > "$state/.subsuper-escalations"
  printf 1000 > "$state/.subsuper-escalations.since"
  fm_daemon_receipt_stage "$state" 'Supervisor escalate: actionable one' "$state/.subsuper-escalations" || fail 'work staging failed'
  fm_daemon_receipt_tick "$state"
  [ -s "$state/.subsuper-escalations" ] || fail 'submit retired unconsumed work'
  load_token; work_token=$token
  printf 'actionable two\n' >> "$state/.subsuper-escalations"
  receiver_ack "$token" || fail 'work receiver ack failed'
  fm_daemon_receipt_tick "$state"
  [ "$(cat "$state/.subsuper-escalations")" = 'actionable two' ] || fail 'ack retired new work or retained consumed prefix'
  fm_daemon_receipt_stage "$state" 'Supervisor escalate: actionable two' "$state/.subsuper-escalations" || fail 'subsequent work staging failed'
  ! receiver_ack "$work_token" || fail 'replayed previous work ack accepted'
  clock=1060
  fm_daemon_receipt_tick "$state" || true
  assert_contains "$(fm_receipt_status "$state")" 'coverage unhealthy' 'loss after successful handoff stayed verified'
  [ -s "$state/.subsuper-escalations" ] || fail 'failed later delivery lost actionable work'
  fm_receipt_invalidate "$state"
  assert_contains "$(fm_receipt_status "$state")" 'coverage inactive' 'return retained coverage'
  ! receiver_ack "$work_token" || fail 'return accepted obsolete ack'
  fm_afk_clear_stale_artifacts "$state" || fail 'fresh entry cleanup failed'
  [ -s "$state/.subsuper-escalations" ] || fail 'fresh entry erased unacknowledged work'
  pass 'work consumption retires only its snapshot; later loss and return preserve new work'
) || exit 1

(
  setup identity
  load_token; old=$token
  fm_receipt_begin "$state" tmux '%fixture' || fail 'restart failed'
  ! receiver_ack "$old" || fail 'previous generation ack accepted'
  load_token
  mkdir -p "$TMP_ROOT/wrong-home"
  ! FM_HOME="$TMP_ROOT/wrong-home" receiver_ack "$token" || fail 'wrong home accepted'
  session='other-session'
  ! receiver_ack "$token" || fail 'wrong session accepted'
  session='fixture-session'
  fm_receipt_receiver() { return 1; }
  ! fm_receipt_ack "$state" "$token" || fail 'wrong receiver accepted'
  session='new-incarnation'
  assert_contains "$(fm_receipt_status "$state")" 'coverage unhealthy' 'new session reused old coverage'
  pass 'restart, wrong home, session incarnation, and wrong receiver reject obsolete acknowledgments'
) || exit 1

(
  setup idle
  load_token; receiver_ack "$token" || fail 'handoff ack failed'
  fm_daemon_receipt_tick "$state"
  clock=1120
  fm_daemon_receipt_tick "$state"
  load_token
  [ "$(fm_receipt_field .pending.kind)" = probe ] || fail 'idle probe missing'
  assert_contains "$(fm_receipt_status "$state")" 'coverage pending' 'idle check self-certified'
  clock=1180
  fm_daemon_receipt_tick "$state" || true
  assert_contains "$(fm_receipt_status "$state")" 'coverage unhealthy' 'idle delivery loss never expired'
  pass 'infrequent idle check detects delivery loss after a successful handoff'
) || exit 1

(
  setup deadline-during-proof
  load_token
  fm_receipt_receiver() { clock=1060; return 0; }
  ! fm_receipt_ack "$state" "$token" || fail 'ack accepted after identity proof crossed the deadline'
  pass 'receiver identity work cannot extend the absolute acknowledgment deadline'
) || exit 1

(
  setup ack-during-digest
  load_token; receiver_ack "$token" || fail 'initial receipt failed'
  printf 'first action\n' > "$state/.subsuper-escalations"
  fm_daemon_receipt_stage "$state" 'first digest' "$state/.subsuper-escalations" || fail 'first work challenge failed'
  load_token; receiver_ack "$token" || fail 'work receipt failed'
  printf 'new action\n' >> "$state/.subsuper-escalations"
  ! fm_daemon_receipt_stage "$state" 'digest built before retirement' "$state/.subsuper-escalations" \
    || fail 'staging reused a digest built before acknowledged work retired'
  fm_daemon_receipt_tick "$state"
  [ "$(cat "$state/.subsuper-escalations")" = 'new action' ] || fail 'tick did not preserve only the new action'
  fm_daemon_receipt_stage "$state" 'new digest' "$state/.subsuper-escalations" || fail 'fresh digest could not stage'
  pass 'ack arriving during digest construction requires retirement before a fresh digest is built'
) || exit 1

(
  setup receipt-lock-loss
  clock=1060
  fm_receipt_lock() { return 1; }
  fm_daemon_receipt_tick "$state" || true
  assert_contains "$(cat "$state/alarms")" WEDGED 'receipt lock loss silently suppressed the expiry alarm'
  assert_contains "$(fm_receipt_status "$state")" 'coverage unhealthy' 'locked expired receipt reported healthy'
  pass 'receipt lock failure cannot suppress independent expiry alarm dispatch'
) || exit 1

# Public CLI with separate producer/receiver processes and the real ownership
# check. The named Python harness is a fixture, not a vendor/live proof.
(
  fixture="$TMP_ROOT/cli"
  mkdir -p "$fixture/home/state"
  receiver_pid='' producer_pid=''
  # shellcheck disable=SC2329 # Invoked by this isolated scenario's EXIT trap.
  cleanup_cli() {
    [ -z "$producer_pid" ] || kill "$producer_pid" 2>/dev/null || true
    [ -z "$receiver_pid" ] || kill "$receiver_pid" 2>/dev/null || true
    wait 2>/dev/null || true
  }
  trap cleanup_cli EXIT
  cat > "$fixture/codex" <<'PY'
import os, pathlib, subprocess, time
root = pathlib.Path(os.environ['RECEIPT_FIXTURE'])
while True:
    request = root / 'request'
    if request.exists():
        pane, token = request.read_text().split()
        request.unlink()
        result = subprocess.run([os.environ['RECEIPT_CLI'], 'ack-supervisor', token],
                                env=dict(os.environ, TMUX_PANE=pane), capture_output=True)
        (root / 'receiver-error').write_bytes(result.stderr)
        (root / 'result.tmp').write_text(str(result.returncode))
        (root / 'result.tmp').replace(root / 'result')
    time.sleep(.05)
PY
  export RECEIPT_FIXTURE="$fixture" RECEIPT_CLI="$ROOT/bin/fm-operational-input.sh"
  export FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$fixture/home/state"
  python3 "$fixture/codex" & receiver_pid=$!
  printf '%s\n' "$receiver_pid" > "$FM_STATE_OVERRIDE/.lock"
  touch "$FM_STATE_OVERRIDE/.afk"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-supervision-engine-lib.sh"
    . "$1/bin/fm-supervisor-receipt.sh"
    fm_receipt_destination() { printf "%%fixture\n"; }
    fm_receipt_begin "$FM_STATE_OVERRIDE" tmux "%fixture" || exit 1
    token=$(jq -r .pending.token "$FM_STATE_OVERRIDE/.supervisor-receipt.json")
    # Even with the receiver pane environment, the producer subtree cannot ack.
    TMUX_PANE=%fixture "$1/bin/fm-operational-input.sh" ack-supervisor "$token" > "$RECEIPT_FIXTURE/producer-result" 2>&1
    printf "%s\n" "$?" > "$RECEIPT_FIXTURE/producer-status"
    while :; do sleep 1; done
  ' _ "$ROOT" & producer_pid=$!
  for _ in $(seq 1 200); do [ ! -f "$fixture/producer-status" ] || break; sleep .05; done
  [ "$(cat "$fixture/producer-status")" != 0 ] || fail 'public CLI accepted producer self-certification'
  token=$(jq -r .pending.token "$FM_STATE_OVERRIDE/.supervisor-receipt.json")
  printf '%%wrong %s\n' "$token" > "$fixture/request.tmp"
  mv "$fixture/request.tmp" "$fixture/request"
  for _ in $(seq 1 200); do [ ! -f "$fixture/result" ] || break; sleep .05; done
  [ "$(cat "$fixture/result")" != 0 ] || fail 'public CLI accepted wrong destination'
  rm "$fixture/result"
  printf '%%fixture %s\n' "$token" > "$fixture/request.tmp"
  mv "$fixture/request.tmp" "$fixture/request"
  for _ in $(seq 1 200); do [ ! -f "$fixture/result" ] || break; sleep .05; done
  if [ "$(cat "$fixture/result")" != 0 ]; then
    cat "$fixture/receiver-error" >&2
    "$ROOT/bin/fm-operational-input.sh" coverage >&2
    fail 'public CLI rejected intended receiver'
  fi
  "$ROOT/bin/fm-operational-input.sh" coverage | grep -q 'coverage verified' || fail 'public CLI ack did not verify coverage'
  pass 'public CLI accepts only the lock-owning receiver at its intended pane, never the producer subtree'
) || exit 1

(
  setup native-scope
  LOG="$state/daemon.log"
  for backend in rex t3code; do
    fm_daemon_receipt_start "$state" "$backend" native-target || fail "$backend receipt gap refused startup"
    [ "$FM_RECEIPT_ACTIVE" = 0 ] || fail "$backend enabled an unsupported receipt obligation"
    fm_receipt_load "$state" || fail 'native transition lost receipt invalidation'
    [ "$(fm_receipt_field .phase)" = inactive ] || fail 'native transition retained obsolete authority'
    FM_SUPERVISOR_BACKEND=$backend
    assert_contains "$(fm_receipt_status "$state")" 'coverage unverified' 'native coverage claimed a receiver proof'
  done
  ! fm_daemon_receipt_start "$state" unsupported native-target || fail 'unknown backend silently exempted'
) || exit 1
pass 'native Rex/T3 retain delivery without receipt startup refusal or a verified coverage claim'

(
  setup native-artifact
  LOG="$state/daemon.log"
  wedge_alarm_rex_clear() { touch "$state/alarm-cleared"; }
  fm_daemon_receipt_tick "$state"
  assert_absent "$state/alarm-cleared" 'transport submission cleared the consumption alarm'
  handoff_token=$(jq -r .pending.token "$state/.supervisor-receipt.json")
  receiver_ack "$handoff_token" || fail 'handoff ack rejected'
  fm_daemon_receipt_tick "$state"
  [ -f "$state/alarm-cleared" ] || fail 'receiver ack did not clear the independent alarm'
  rm -f "$state/alarm-cleared"
  escalate_add "$state" 'preserved native artifact'
  escalate_freeze "$state/.subsuper-escalations" 'old native message' old-native-id || fail 'fixture freeze failed'
  escalate_flush "$state" || true
  [ -s "$state/.subsuper-escalations" ] || fail 'native artifact bypassed the consumption receipt'
  assert_absent "$state/alarm-cleared" 'work submission cleared the consumption alarm'
  fm_receipt_load "$state"
  [ "$(fm_receipt_field .pending.kind)" = work ] || fail 'work did not stage a receiver obligation'
  [ "$(fm_receipt_field '.pending.acked | tostring')" = false ] || fail 'old transport artifact certified consumption'
) || exit 1
pass 'native freeze leftovers cannot bypass a pane receipt and alarm clearing requires consumption'

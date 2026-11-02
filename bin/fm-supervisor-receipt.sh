#!/usr/bin/env bash
# Supervisor consumption receipts, shared by the daemon and operational-input CLI.
# This is receipt state for the existing daemon, not another supervision owner.
#
# Scope: tmux and Herdr only. Rex and T3 Code retain their upstream delivery
# behavior without a consumption obligation, including T3 frozen-digest
# retirement on transport confirmation. Their native receiving-conversation
# identity is not established; native coverage must never be called verified.
#
# One atomic JSON record, state/.supervisor-receipt.json, is serialized through
# .supervisor-receipt.lock using the existing portable lock primitives. It binds
# physical home/state, primary session key (including process incarnation),
# destination backend/pane, producer process identity, a fresh daemon generation,
# and one random challenge. Only ack from the lock-owning receiving conversation
# may verify it; transport submission never does. An actionable snapshot stays
# in the existing escalation buffer until the daemon reconciles that exact ack.
#
# FM_SUPERVISOR_ACK_SECS: positive seconds to consume a challenge (default 600,
# maximum 3600), including busy turns. FM_SUPERVISOR_RETRY_SECS: retry interval
# (default 30, maximum 300). FM_SUPERVISOR_IDLE_SECS: idle probe interval after
# an ack (default 900, maximum 3600). Invalid settings refuse daemon startup.
# The daemon checks every loop and each backoff second, including target loss,
# independently of batching. Existing guarded transport and housekeeping work
# serialize checks; expiry is observed on the next check, never extended by a
# retry or a busy primary. The alert notifier has its own existing time bound.
# Expiry stops retries, invalidates coverage, and uses the existing wedge alarm.
# Busy turns do not pause deadlines: a turn exceeding the budget is unhealthy.
# Every daemon start creates a new generation; session change or return
# invalidates it and requires a fresh explicit start.
# No restoration or atomic submit is promised. status also checks expiry and
# identity, so a stale verified record never reports current coverage.
#
# Source after fm-wake-lib.sh and fm-supervision-engine-lib.sh. CLI consumers
# enter through fm-operational-input.sh ack-supervisor <challenge> or coverage.

fm_receipt_now() { date +%s; }

fm_receipt_settings() {
  FM_RECEIPT_ACK_SECS=${FM_SUPERVISOR_ACK_SECS:-600}
  FM_RECEIPT_RETRY_SECS=${FM_SUPERVISOR_RETRY_SECS:-30}
  FM_RECEIPT_IDLE_SECS=${FM_SUPERVISOR_IDLE_SECS:-900}
  local value
  for value in "$FM_RECEIPT_ACK_SECS" "$FM_RECEIPT_RETRY_SECS" "$FM_RECEIPT_IDLE_SECS"; do
    case "$value" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#value}" -le 4 ] && [ "$value" -le 3600 ] || return 1
  done
  [ "$FM_RECEIPT_RETRY_SECS" -le 300 ]
}

fm_receipt_lock() { fm_lock_acquire_wait_max "$1/.supervisor-receipt.lock" 2; }
fm_receipt_unlock() { fm_lock_release "$1/.supervisor-receipt.lock"; }
fm_receipt_load() {
  FM_RECEIPT=$(cat "$1/.supervisor-receipt.json" 2>/dev/null) || return 1
  printf '%s' "$FM_RECEIPT" | jq -e '
    type == "object" and .version == 1
    and ([.home,.state,.session,.target,.producer_identity] | all(type == "string" and length > 0))
    and (.backend == "tmux" or .backend == "herdr")
    and (.generation | type == "string" and test("^[0-9a-f]{48}$"))
    and (.producer | type == "number" and . > 0)
    and ([.last_ack,.started,.ack_secs,.idle_secs] | all(type == "number" and . >= 0))
    and (.phase == "pending" or .phase == "verified" or .phase == "unhealthy" or .phase == "inactive")
    and (if .phase == "inactive" then .pending == null else
      .pending | type == "object"
      and (.token | type == "string" and test("^[0-9a-f]{48}$"))
      and (.kind == "probe" or .kind == "work")
      and ([.payload,.snapshot] | all(type == "string"))
      and ([.created,.deadline,.next_attempt,.attempts] | all(type == "number" and . >= 0))
      and ([.acked,.submitted] | all(type == "boolean"))
    end)' >/dev/null
}
fm_receipt_field() { printf '%s' "$FM_RECEIPT" | jq -er "$1"; }
fm_receipt_save() {
  local tmp
  tmp=$(mktemp "$1/.supervisor-receipt.XXXXXX") || return 1
  if printf '%s\n' "$FM_RECEIPT" > "$tmp" && mv -f "$tmp" "$1/.supervisor-receipt.json"; then return 0; fi
  rm -f "$tmp"
  return 1
}
fm_receipt_nonce() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }

fm_receipt_destination() {  # <backend> <target>
  case "$1" in
    tmux) tmux display-message -p -t "$2" '#{pane_id}' ;;
    herdr) printf '%s\n' "$2" ;;
    *) return 1 ;;
  esac
}

fm_receipt_context_current() {  # <state>
  local home state key pid identity
  [ -f "$1/.afk" ] && [ ! -e "$1/.afk-return-catchup" ] || return 1
  home=$(cd "$FM_HOME" && pwd -P) && state=$(cd "$1" && pwd -P) || return 1
  key=$(fm_supervision_host_main_key "$1") && [ -n "$key" ] || return 1
  [ "$home" = "$(fm_receipt_field .home)" ] && [ "$state" = "$(fm_receipt_field .state)" ] \
    && [ "$key" = "$(fm_receipt_field .session)" ] || return 1
  pid=$(fm_receipt_field .producer) && identity=$(fm_pid_identity "$pid") || return 1
  [ "$identity" = "$(fm_receipt_field .producer_identity)" ]
}

fm_receipt_begin() {  # <state> <backend> <target>; called only by daemon owner
  local state=$1 home physical key destination generation pid identity now status=1
  fm_receipt_settings || return 1
  home=$(cd "$FM_HOME" && pwd -P) && physical=$(cd "$state" && pwd -P) || return 1
  key=$(fm_supervision_host_main_key "$state") || key=unavailable
  destination=$(fm_receipt_destination "$2" "$3") && [ -n "$destination" ] || return 1
  generation=$(fm_receipt_nonce) && [ -n "$generation" ] || return 1
  fm_current_pid pid && identity=$(fm_pid_identity "$pid") || return 1
  now=$(fm_receipt_now)
  fm_receipt_lock "$state" || return 1
  FM_RECEIPT=$(jq -n --arg home "$home" --arg state "$physical" --arg session "$key" \
    --arg backend "$2" --arg target "$destination" --arg generation "$generation" \
    --arg identity "$identity" --argjson pid "$pid" --argjson now "$now" \
    --argjson ack "$FM_RECEIPT_ACK_SECS" --argjson idle "$FM_RECEIPT_IDLE_SECS" \
    '{version:1,home:$home,state:$state,session:$session,backend:$backend,target:$target,
      generation:$generation,producer:$pid,producer_identity:$identity,phase:"pending",
      last_ack:0,pending:null,started:$now,ack_secs:$ack,idle_secs:$idle}') \
    && fm_receipt_challenge_locked "$state" probe 'Supervision handoff probe.' '' && status=0
  fm_receipt_unlock "$state"
  return "$status"
}

fm_receipt_challenge_locked() {  # <state> <probe|work> <payload> <snapshot-file-or-empty>
  local token now snapshot_file=${4:-/dev/null}
  token=$(fm_receipt_nonce) && [ -n "$token" ] || return 1
  now=$(fm_receipt_now)
  FM_RECEIPT=$(printf '%s' "$FM_RECEIPT" | jq --arg token "$token" --arg kind "$2" \
    --arg payload "$3" --rawfile snapshot "$snapshot_file" --argjson now "$now" --argjson budget "$FM_RECEIPT_ACK_SECS" \
    '.phase="pending" | .pending={token:$token,kind:$kind,payload:$payload,snapshot:$snapshot,
      created:$now,deadline:($now+$budget),next_attempt:$now,attempts:0,submitted:false,acked:false}') \
    && fm_receipt_save "$1"
}

fm_receipt_invalidate() {  # <state>; return/stop, including a failed start
  local status=0
  [ -f "$1/.supervisor-receipt.json" ] || return 0
  fm_receipt_lock "$1" || {
    printf 'Supervisor invalidation deferred: receipt lock unavailable; lifecycle preserved.\n' >&2
    return 1
  }
  fm_receipt_load "$1" && FM_RECEIPT=$(printf '%s' "$FM_RECEIPT" | jq '.phase="inactive" | .pending=null') \
    && fm_receipt_save "$1" || status=1
  fm_receipt_unlock "$1"
  return "$status"
}

# A daemon launched beneath a primary can inherit its pane/session environment.
# Reject that entire process subtree before the ordinary receiver ownership proof.
fm_receipt_receiver() {  # <state>
  local pid producer backend target hops=0
  producer=$(fm_receipt_field .producer) || return 1
  fm_current_pid pid || return 1
  while [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
    [ "$pid" != "$producer" ] || return 1
    pid=$(ps -p "$pid" -o ppid= | tr -d ' ') || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    hops=$((hops + 1))
  done
  [ "$hops" -lt 64 ] || return 1
  fm_session_lock_owned_by_self "$1" || return 1
  # Never trust the producer's FM_SUPERVISOR_* overrides as receiver evidence.
  if [ -n "${TMUX_PANE:-}" ]; then backend=tmux; target=$TMUX_PANE
  elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    backend=herdr; target="${HERDR_SESSION:-default}:$HERDR_PANE_ID"
  else return 1; fi
  [ "$backend" = "$(fm_receipt_field .backend)" ] && [ "$target" = "$(fm_receipt_field .target)" ]
}

fm_receipt_ack() {  # <state> <token>; explicit receiving-conversation operation
  local state=$1 token=$2 now status=1
  fm_receipt_lock "$state" || return 1
  now=$(fm_receipt_now)
  case "$token" in ''|*[!0-9a-f]*) fm_receipt_unlock "$state"; return 1 ;; esac
  if fm_receipt_load "$state" && fm_receipt_context_current "$state" \
    && fm_receipt_receiver "$state" \
    && [ "$token" = "$(fm_receipt_field .pending.token)" ] \
    && now=$(fm_receipt_now) \
    && [ "$now" -lt "$(fm_receipt_field .pending.deadline)" ] \
    && [ "$(fm_receipt_field .phase)" != unhealthy ]; then
    if [ "$(fm_receipt_field '.pending.acked | tostring')" = true ]; then status=0
    elif FM_RECEIPT=$(printf '%s' "$FM_RECEIPT" | jq --argjson now "$now" \
      '.pending.acked=true | .phase="verified" | .last_ack=$now') && fm_receipt_save "$state"; then status=0; fi
  fi
  fm_receipt_unlock "$state"
  return "$status"
}

fm_receipt_status() {  # <state>; read-only, never certifies a receipt
  local phase now
  case "${FM_SUPERVISOR_BACKEND:-}" in
    rex|t3code)
      printf 'coverage unverified (%s receiving-conversation identity not supported)\n' "$FM_SUPERVISOR_BACKEND"
      return
      ;;
  esac
  if ! fm_receipt_load "$1"; then
    if [ -e "$1/.supervisor-receipt.json" ]; then printf 'coverage unhealthy (receipt unreadable)\n'
    else printf 'coverage pending (no daemon handshake)\n'; fi
    return
  fi
  phase=$(fm_receipt_field .phase)
  if [ "$phase" = inactive ]; then printf 'coverage inactive\n'; return; fi
  now=$(fm_receipt_now)
  if ! fm_receipt_context_current "$1" \
    || { [ "$(fm_receipt_field .last_ack)" -gt 0 ] && [ "$now" -ge "$(( $(fm_receipt_field .last_ack) + $(fm_receipt_field .idle_secs) + $(fm_receipt_field .ack_secs) ))" ]; } \
    || { [ "$(fm_receipt_field '.pending.acked // false | tostring')" != true ] \
      && [ "$now" -ge "$(fm_receipt_field '.pending.deadline // 0')" ]; }; then phase=unhealthy; fi
  printf 'coverage %s (receiver acknowledgment; generation=%s; last_ack=%s)\n' \
    "$phase" "$(fm_receipt_field .generation)" "$(fm_receipt_field .last_ack)"
}

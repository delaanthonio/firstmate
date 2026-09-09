#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and requires a durable captain decision
# record before it closes or repairs a hold.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh answer <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh answers <origin-id> --source <provenance>   (keyed answers on stdin)
#   fm-decision-hold.sh bind <source-id> <origin-id>
#   fm-decision-hold.sh unbind <source-id>
#   fm-decision-hold.sh binding <source-id>
#   fm-decision-hold.sh decline <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh repair <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh preserve-question <origin-id> <decision-key> \
#     --state existing|unseeded --question-file <path>
#   fm-decision-hold.sh open-questions [--render]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve`, `answer`, and `decline` close active holds; `repair` attests a hold
# already closed outside this script. All four paths require a non-empty captain
# decision file of at most 8192 bytes, record the same durable resolution block in
# the hold body, and store the decision digest plus routed identities so an exact
# retry is idempotent while a changed decision or, for `resolve`, routed set is
# rejected. New records include a `Resolution mode:` naming their path; older
# routed records remain valid.
#
# `resolve` is the routed path. It requires every --routed-to task to exist and to
# be blocked by the hold. It writes the captain decision and routed identities into
# the hold body, clears those dependency edges, and only then marks the hold Done.
# A failure before the final step leaves the captain hold open.
#
# `answer` is the answer-time closure path, the hold ledger's counterpart to
# `fm-send.sh --resolve-key`: it exists so the act that carries the captain's
# answer is the act that closes the hold, instead of leaving closure to a
# separate later call nobody is forced to make. It records the captain's answer
# on an actively held hold, records `(none)` as the routed identities because no
# follow-up work has been routed behind the hold yet, and closes it. It shares
# every guard `decline` has, including the refusal while any task is still
# blocked by the hold, so a decision whose follow-up work is already routed still
# goes through `resolve` and the routed-vs-unrouted distinction survives. It says
# only that the captain answered; `decline` still says the captain answered with
# no follow-up work at all.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer closes its matching hold" is a single capability, owned here
# and nowhere else. `answers` is its channel-agnostic entry point: it reads
# `<decision-key>\t<answer>\t<label>` lines on stdin, maps each key to this
# origin's `<origin-id>-decision-<key>` hold, and closes it through the very same
# `answer` path above, so every guard applies identically no matter which channel
# the answer arrived on. `--source` is provenance text recorded in the durable
# decision, never a behavior switch: this command has no per-channel branch and
# no knowledge of chat, review decks, or any transport.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines and
# pipe them here. It must never map keys to holds, build decision records, decide
# resolve-versus-decline, or close a hold itself. A future channel needs no change
# here at all.
#
# The decision text is a pure function of (source, key, answer, label), which is
# what makes a replayed delivery an idempotent no-op rather than a rejected
# "different captain decision". A key whose hold is absent, already closed, or
# still blocking routed work is reported as `skipped:` and left for `resolve`;
# skipping is never forced closure, and the command exits nonzero when any key
# was skipped.
#
# `bind`, `unbind`, and `binding` record which origin a captured-answer SOURCE
# belongs to, for any channel whose answers arrive detached from the origin (a
# process-event source id, for example). The binding is a private record under
# `state/decision-bindings/`; a source with no binding feeds nothing, so this
# whole path is opt-in per source and an unbound source behaves as if it did not
# exist. `bind` deliberately does not require the source to exist yet, so a
# channel can be bound BEFORE it is armed and never produce an answer that has
# nowhere to go.
#
# `decline` is the unrouted path for a decision the captain answered with no
# follow-up work. It takes no --routed-to task, records `(none)` as the routed
# identities, and closes an actively held hold. It refuses while any task is still
# blocked by the hold, because releasing routed work without recording it is
# `resolve`'s job.
#
# `repair` records the missing resolution block on a hold that was already closed
# outside this script, so `verify` stops failing on an origin whose decision was
# genuinely answered. It never reopens a hold, never clears a dependency edge, and
# refuses a hold that is still actively held, so an unanswered decision keeps
# blocking teardown until `resolve` or `decline` closes it with the captain's word.
# It also refuses an identity that does not carry surviving captain-hold
# provenance, so an ordinary captain-kind task cannot be repaired into a decision.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

DECISION_META_LOCK=
DECISION_META_LOCK_HELD=0
decision_hold_cleanup() {
  if [ "$DECISION_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK" || true
    DECISION_META_LOCK_HELD=0
  fi
}
trap decision_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

# The routed-identity token recorded when a close path routes no work. Slug
# validation rejects parentheses, so no real task identity can collide with it.
ROUTED_NONE='(none)'

DECISION_TEXT=''
DECISION_DIGEST=''

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

body_has_resolution_record() {  # <hold-body>
  case "$1" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

resolution_body() {  # <mode> <routed-csv> [routed-task-id...]
  local mode=$1 routed_csv=$2 body dep
  shift 2
  # Command substitution strips the trailing newline, so restore it before the
  # routed-work list to keep each entry on its own durable backlog line.
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$DECISION_DIGEST" "$routed_csv" "$mode" "$DECISION_TEXT")
  body="${body}"$'\n'
  if [ "$#" -eq 0 ]; then
    body="${body}${ROUTED_NONE}"$'\n'
  else
    for dep in "$@"; do
      body="${body}- ${dep}"$'\n'
    done
  fi
  printf '%s' "$body"
}

# tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
normalized_blocked_by() {  # <show-output>
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  printf '%s' "$blocked"
}

# Space-separated ids of live work still blocked by <hold-id>. The listing is only
# a cheap prefilter whose first field is always an unquoted id; every candidate is
# confirmed against its own authoritative record before it is reported.
tasks_blocked_by() {  # <hold-id>
  local id=$1 rows row candidate show found=''
  rows=$(tasks_axi list --fields blocked_by) \
    || fail "could not read backlog work while checking what $id still blocks"
  while IFS= read -r row; do
    case "$row" in
      *"$id"*) : ;;
      *) continue ;;
    esac
    candidate=${row%%,*}
    candidate=${candidate// /}
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$id" ] || continue
    case "$candidate" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    show=$(task_show "$candidate") || continue
    list_has_key "$(normalized_blocked_by "$show")" "$id" || continue
    found="${found}${found:+ }$candidate"
  done <<EOF
$rows
EOF
  printf '%s' "$found"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  body_has_resolution_record "$body"
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ] && body_has_resolution_record "$body"; then
    return 0
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

# --- Deferred away-mode approval questions -------------------------------
#
# `preserve-question` is the ONE idempotent operation that files an approval
# question attempted while away mode is active. The caller supplies the
# authoritative `(origin,key)` binding; this command never derives one from
# question prose, a questionnaire topic, session identity, or a working
# directory. It routes the attempt to whichever owner already holds that
# decision - the captain hold when one is active, otherwise the origin's own
# status ledger - and creates an ordinary captain hold only when the binding
# explicitly says the decision is unseeded. A binding that matches no owner
# while claiming `existing` is rejected, because silently creating a decision
# the caller believed already existed would hide the real one.
#
# Evidence is digest-addressed, so an exact replay after a restart, a
# compaction, or a repeated operational notification finds its own digest
# already stored and changes nothing, while a substantively different attempt
# under the same key is retained as another variant of one unresolved decision.
# A created hold's title is derived from the key rather than the question
# wording, so a reworded variant can never collide with the stable identity.
QUESTION_MARKER='droid-afk-question'
QUESTION_MAX_BYTES=8192
QUESTION_CHUNK_CHARS=800

BASE64_DECODE_FLAG=''
base64_decode_flag() {
  if [ -z "$BASE64_DECODE_FLAG" ]; then
    if printf 'eA==' | base64 -d >/dev/null 2>&1; then
      BASE64_DECODE_FLAG='-d'
    else
      BASE64_DECODE_FLAG='-D'
    fi
  fi
  printf '%s' "$BASE64_DECODE_FLAG"
}

# Base64 keeps an arbitrary question block on one status line and out of every
# quoting, escaping, and multibyte boundary this repo's ledgers care about.
encode_question() {  # <text>
  printf '%s' "$1" | LC_ALL=C base64 | LC_ALL=C tr -d '\n'
}

decode_question() {  # <encoded>
  printf '%s' "$1" | LC_ALL=C base64 "$(base64_decode_flag)"
}

# tasks-axi renders a body containing whitespace or a quote as one escaped and
# quoted line. Decode it back to the exact stored bytes, refusing an escape this
# writer never produces rather than silently corrupting a hand-edited body.
decode_body() {  # <rendered-body-field>
  local raw=$1 rc=0 out
  case "$raw" in
    ''|'""') printf ''; return 0 ;;
    '"'*'"') raw=${raw#\"}; raw=${raw%\"} ;;
    *) printf '%s' "$raw"; return 0 ;;
  esac
  out=$(printf '%s' "$raw" | LC_ALL=C awk '
    {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c != "\\") { printf "%s", c; continue }
        i++
        e = substr($0, i, 1)
        if (e == "n") printf "\n"
        else if (e == "t") printf "\t"
        else if (e == "\"") printf "\""
        else if (e == "\\") printf "\\"
        else exit 3
      }
    }') || rc=$?
  [ "$rc" -eq 0 ] || fail "captain hold body carries an unsupported escape sequence"
  printf '%s' "$out"
}

hold_is_active() {  # <hold-id>
  local show=''
  show=$(task_show "$1") || return 1
  [ "$(show_field "$show" state)" = queued ] || return 1
  [ "$(show_field "$show" held)" = yes ] || return 1
  [ "$(show_field "$show" kind)" = captain ] || return 1
  [ "$(show_field "$show" hold_kind)" = captain ] || return 1
  return 0
}

status_open_verb() {  # <status-file> <decision-key>
  status_open_decisions "$1" | LC_ALL=C awk -F '\t' -v k="$2" '$1 == k { print $2; exit }'
}

# The question's own first line, for the capped ordinary drain view only. The
# lossless block always travels in the encoded evidence beside it, so this
# summary is never the record.
question_summary() {  # <question-text>
  local summary
  summary=$(printf '%s\n' "$1" | sed -n '1p' | LC_ALL=C tr '\t\r' '  ')
  printf '%s' "$summary"
}

preserve_in_hold() {  # <hold-id> <digest> <encoded>
  local id=$1 digest=$2 encoded=$3 show body
  show=$(task_show "$id") || fail "captain hold $id disappeared while preserving a question"
  body=$(decode_body "$(show_field "$show" body)")
  case "$body" in
    *"$QUESTION_MARKER $digest"*) return 0 ;;
  esac
  # Command substitution already stripped any trailing newline from the body.
  [ -z "$body" ] || body="${body}"$'\n'
  body="${body}${QUESTION_MARKER} ${digest}"$'\n'"${encoded}"
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not preserve the attempted question on $id"
}

preserve_in_status() {  # <status-file> <key> <verb> <summary> <digest> <encoded>
  local status_file=$1 key=$2 verb=$3 summary=$4 digest=$5 encoded=$6 rc=0
  if status_question_evidence "$status_file" "$key" \
      | LC_ALL=C awk -F '\t' -v digest="$digest" '$1 == digest { found = 1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi
  fm_wake_status_append_self_announced "$STATE" "$status_file" \
    "$verb [key=$key]: $summary | $QUESTION_MARKER $digest $encoded" || rc=$?
  [ "$rc" -ne 2 ] || fail "cannot preserve the attempted question for [key=$key]"
}

# An interrupted status-to-hold transfer leaves both a durable hold and a raw
# open status key. The hold is authoritative, so finish the established transfer
# instead of ever reopening status - fm-send.sh resolves status first, so a
# reopened duplicate would swallow the answer the real hold is waiting for.
finish_status_transfer() {  # <origin> <key> <hold-id> <status-file>
  local origin=$1 key=$2 id=$3 status_file=$4 rc=0
  [ -f "$status_file" ] || return 0
  [ -n "$(status_open_verb "$status_file" "$key")" ] || return 0
  fm_wake_status_append_self_announced "$STATE" "$status_file" \
    "captain-held [key=$key]: tracked by $id" || rc=$?
  [ "$rc" -ne 2 ] || fail "cannot finish the captain-held transfer for $origin/$key"
}

command_preserve_question() {
  local origin=${1:-} key=${2:-} state='' question_file='' \
    id status_file meta question digest encoded summary verb
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) shift; state=${1:-} ;;
      --question-file) shift; question_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  case "$state" in
    existing|unseeded) ;;
    *) fail "--state must be existing or unseeded" ;;
  esac
  [ -n "$question_file" ] || fail "--question-file is required"
  [ -f "$question_file" ] || fail "question file does not exist: $question_file"
  question=$(cat "$question_file")
  [ -n "$question" ] || fail "question file must not be empty"
  [ "$(printf '%s' "$question" | LC_ALL=C wc -c | tr -d ' ')" -le "$QUESTION_MAX_BYTES" ] \
    || fail "question file exceeds $QUESTION_MAX_BYTES bytes"
  digest=$(sha256_text "$question")
  encoded=$(encode_question "$question")
  summary=$(question_summary "$question")
  [ -n "$summary" ] || summary="deferred away-mode approval question"

  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  meta="$STATE/$origin.meta"
  if [ -f "$meta" ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while preserving a question"
  fi
  id=$(hold_id "$origin" "$key")
  status_file="$STATE/$origin.status"

  if hold_is_active "$id"; then
    preserve_in_hold "$id" "$digest" "$encoded"
    finish_status_transfer "$origin" "$key" "$id" "$status_file"
    printf 'preserved: hold %s\n' "$id"
    return 0
  fi

  verb=$(status_open_verb "$status_file" "$key")
  if [ -n "$verb" ]; then
    preserve_in_status "$status_file" "$key" "$verb" "$summary" "$digest" "$encoded"
    printf 'preserved: status %s/%s\n' "$origin" "$key"
    return 0
  fi

  [ "$state" = unseeded ] || fail \
    "binding claims state=existing but $origin/$key has no active captain hold and no open status decision; re-attempt with the owner's real key or state=unseeded"

  command_hold "$origin" "$key" \
    --title "Deferred away-mode approval question $key" \
    --reason "deferred away-mode approval question awaiting captain decision" >/dev/null
  preserve_in_hold "$id" "$digest" "$encoded"
  printf 'preserved: hold %s\n' "$id"
}

# --- Outstanding-question projection --------------------------------------
#
# `open-questions` is a read-only union of the two owners, for the away-mode
# return catch-up to present. It is a projection, never a third source of truth.
#
# It reads the RAW status fold rather than origin_open_decisions, because a
# worker that legitimately continued independently authorized work, or that
# later reached a terminal state, must not make its unanswered question vanish
# from the captain's return listing.
#
# Rows are keyed by `(origin,key)` and an active captain hold wins, so an
# interrupted transfer still presents exactly one item. Preserved question
# blocks are emitted as base64 chunks: concatenating a variant's chunks in
# order and decoding reproduces the stored bytes exactly, so no cap, no
# multibyte boundary, and no omission can corrupt a returned question.
#
# Records, TAB-separated:
#   decision  <item> <origin> <key> <owner> <summary>
#   chunk     <item> <variant> <chunk> <chunks> <base64>
#   limitation <text>
status_question_evidence() {  # <status-file> <decision-key>
  LC_ALL=C awk -v key="[key=$2]:" -v marker="$QUESTION_MARKER" '
    index($0, key) > 0 {
      for (i = 1; i + 2 <= NF; i++) {
        if ($i == marker) print $(i + 1) "\t" $(i + 2)
      }
    }
  ' "$1" 2>/dev/null || true
}

status_question_variants() {  # <status-file> <decision-key>
  status_question_evidence "$1" "$2" | LC_ALL=C cut -f2
}

hold_question_variants() {  # <decoded-hold-body>
  printf '%s\n' "$1" | LC_ALL=C awk -v marker="$QUESTION_MARKER" '
    $1 == marker && NF == 2 { if ((getline blob) > 0) print blob }
  '
}

emit_question_chunks() {  # <item> <variant> <encoded>
  local item=$1 variant=$2 encoded=$3 total index=0 chunk
  total=$(printf '%s' "$encoded" | LC_ALL=C fold -w "$QUESTION_CHUNK_CHARS" | LC_ALL=C awk 'END { print NR }')
  [ "$total" -gt 0 ] || total=1
  while IFS= read -r chunk || [ -n "$chunk" ]; do
    index=$((index + 1))
    printf 'chunk\t%s\t%s\t%s\t%s\t%s\n' "$item" "$variant" "$index" "$total" "$chunk"
  done <<EOF
$(printf '%s' "$encoded" | LC_ALL=C fold -w "$QUESTION_CHUNK_CHARS")
EOF
}

emit_question_records() {
  local held_ids='' held_rows='' id show body origin key status_file open summary \
    item=0 variant encoded seen=$'\n' pair complete=1

  if fm_tasks_axi_compatible 2>/dev/null; then
    if held_rows=$(tasks_axi list --state held --kind captain 2>/dev/null); then
      held_ids=$(printf '%s\n' "$held_rows" \
        | LC_ALL=C awk -F ',' '/^  [A-Za-z0-9._-]+,/ { sub(/^  /, "", $1); print $1 }')
    else
      printf 'limitation\tcaptain-decision holds could not be listed\n'
      complete=0
    fi
  else
    printf 'limitation\tcompatible tasks-axi is unavailable; captain-decision holds were not read\n'
    complete=0
  fi

  for id in $held_ids; do
    if ! show=$(task_show "$id"); then
      printf 'limitation\tcaptain-decision hold %s could not be read\n' "$id"
      complete=0
      continue
    fi
    body=$(decode_body "$(show_field "$show" body)")
    origin=$(printf '%s\n' "$body" | sed -n 's/^Origin: //p' | head -1)
    key=$(printf '%s\n' "$body" | sed -n 's/^Decision key: //p' | head -1)
    [ -n "$origin" ] && [ -n "$key" ] || continue
    [ "$id" = "$origin-decision-$key" ] || continue
    item=$((item + 1))
    seen="${seen}${origin}/${key}"$'\n'
    printf 'decision\t%s\t%s\t%s\thold\t%s\n' "$item" "$origin" "$key" "$(show_field "$show" title)"
    variant=0
    while IFS= read -r encoded; do
      [ -n "$encoded" ] || continue
      variant=$((variant + 1))
      emit_question_chunks "$item" "$variant" "$encoded"
    done <<EOF
$(hold_question_variants "$body")
EOF
  done

  for status_file in "$STATE"/*.status; do
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
    origin=$(basename "$status_file")
    origin=${origin%.status}
    open=$(status_open_decisions "$status_file")
    [ -n "$open" ] || continue
    while IFS=$'\t' read -r key _verb summary; do
      [ -n "$key" ] || continue
      pair="${origin}/${key}"
      case "$seen" in *$'\n'"$pair"$'\n'*) continue ;; esac
      seen="${seen}${pair}"$'\n'
      item=$((item + 1))
      summary=${summary%% | "$QUESTION_MARKER" *}
      printf 'decision\t%s\t%s\t%s\tstatus\t%s\n' "$item" "$origin" "$key" "$summary"
      variant=0
      while IFS= read -r encoded; do
        [ -n "$encoded" ] || continue
        variant=$((variant + 1))
        emit_question_chunks "$item" "$variant" "$encoded"
      done <<EOF
$(status_question_variants "$status_file" "$key")
EOF
    done <<EOF
$open
EOF
  done
  [ "$complete" -eq 1 ]
}

# Render the same union as the captain-facing catch-up listing. Every variant of
# every outstanding decision is printed; there is no cap and no omission path,
# because a question the captain never sees is a question that was lost.
render_question_records() {  # <records-file>
  local file=$1 variants tag f2 f3 f4 f5 f6 vitem vvariant vblob
  variants=$(LC_ALL=C awk -F '\t' '
    $1 == "chunk" {
      slot = $2 "\t" $3
      if (!(slot in blob)) order[++n] = slot
      blob[slot] = blob[slot] $6
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], blob[order[i]] }
  ' "$file")
  while IFS=$'\t' read -r tag f2 f3 f4 f5 f6; do
    case "$tag" in
      limitation) printf 'outstanding decisions limitation: %s\n' "$f2"; continue ;;
      decision) ;;
      *) continue ;;
    esac
    printf 'outstanding decision %s: %s [key=%s] owner=%s - %s\n' "$f2" "$f3" "$f4" "$f5" "$f6"
    while IFS=$'\t' read -r vitem vvariant vblob; do
      [ "$vitem" = "$f2" ] || continue
      printf 'outstanding decision %s deferred question %s:\n' "$f2" "$vvariant"
      decode_question "$vblob"
      printf '\n'
    done <<VARIANTS
$variants
VARIANTS
  done < "$file"
}

command_open_questions() {
  local render=0 records projection_complete=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --render) render=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  if [ "$render" -ne 1 ]; then
    emit_question_records
    return
  fi
  records=$(mktemp "${TMPDIR:-/tmp}/fm-open-questions.XXXXXX") || fail "could not stage the outstanding-question listing"
  emit_question_records > "$records" || projection_complete=0
  render_question_records "$records"
  rm -f "$records"
  [ "$projection_complete" -eq 1 ]
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    # The transfer line is this home's own bookkeeping close, written by the
    # turn that just reviewed the decision, so it uses the guarded
    # self-announced append (bin/fm-wake-lib.sh) and does not wake this same
    # session; an append failure still fails this command loudly.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      while IFS=$'\t' read -r question_digest question_encoded; do
        [ -n "$question_digest" ] && [ -n "$question_encoded" ] || continue
        preserve_in_hold "$(hold_id "$origin" "$key")" "$question_digest" "$question_encoded"
      done <<QUESTION_EVIDENCE
$(status_question_evidence "$status_file" "$key")
QUESTION_EVIDENCE
      transfer_rc=0
      fm_wake_status_append_self_announced "$STATE" "$status_file" \
        "captain-held [key=$key]: tracked by $(hold_id "$origin" "$key")" || transfer_rc=$?
      [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
      key_seen=1
    done <<EOF
$raw_open
EOF
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use decline when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    blocked=$(normalized_blocked_by "$show")
    if ! list_has_key "$blocked" "$id"; then
      case "$hold_body" in
        *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
        *) fail "routed task $dep is not durably blocked by $id" ;;
      esac
    fi
  done

  # shellcheck disable=SC2086  # routed is a validated space-separated slug list.
  body=$(resolution_body routed "$routed_csv" $routed)
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    if list_has_key "$(normalized_blocked_by "$show")" "$id"; then
      tasks_axi unblock "$dep" --by "$id" >/dev/null \
        || fail "could not route the recorded decision to $dep"
    fi
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

parse_decision_only_flags() {  # <args...>; prints the --decision-file value
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  printf '%s' "$decision_file"
}

# The one unrouted close path, shared by `answer` and `decline`. They differ only
# in the resolution mode they record and the outcome word they print; every
# guard - the captain decision file, the active-hold requirement, the retry
# identity, and the refusal to release still-routed work - is identical, so
# neither can drift into a weaker close than the other.
close_unrouted_hold() {  # <mode> <outcome-word> <origin-id> <decision-key> <flag-args...>
  local mode=$1 outcome=$2 origin=$3 key=$4 decision_file id body hold_show hold_body state dependents
  shift 4
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi
  hold_show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$hold_show" state)
  [ "$state" != "done" ] \
    || fail "captain hold $id was closed outside fm-decision-hold; use repair to record the captain decision"
  verify_hold_active "$id"
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
      ;;
  esac
  dependents=$(tasks_blocked_by "$id") || exit 1
  [ -z "$dependents" ] \
    || fail "captain hold $id still blocks routed work ($dependents); use resolve to record that work"
  body=$(resolution_body "$mode" "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  tasks_axi "done" "$id" >/dev/null || fail "could not close $mode captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf '%s: %s\n' "$outcome" "$id"
}

command_answer() {
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  close_unrouted_hold answered answered "$@"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The origin a captured-answer source belongs to, or empty when it is unbound.
# An unreadable or wrong-schema record is a hard error rather than a silent
# "unbound": feeding nothing is the safe direction only when it is a deliberate
# choice, never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  case "$origin" in
    ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
  esac
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  validate_slug origin-id "$origin"
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

command_answers() {
  local origin=${1:-} source='' key answer label hold tmp err closed=0 skipped=0 reason
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS=$'\t' read -r key answer label; do
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 64 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    hold="$origin-decision-$key"
    keyed_decision_text "$source" "$key" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $hold"
    if "$0" answer "$origin" "$key" --decision-file "$tmp" >/dev/null 2>"$err"; then
      printf 'closed: %s\n' "$hold"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-decision-hold: //')
      printf 'skipped: %s (%s)\n' "$hold" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s origin=%s\n' "$closed" "$skipped" "$origin"
  [ "$skipped" -eq 0 ]
}

command_decline() {
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  close_unrouted_hold declined declined "$@"
}

command_repair() {
  local origin=${1:-} key=${2:-} decision_file id body show state kind hold_kind hold_body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  kind=$(show_field "$show" kind)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  # tasks-axi keeps hold_kind after a close, so it is the surviving proof that
  # this identity really was a captain hold rather than an ordinary captain-kind
  # task that was never held for the captain at all.
  hold_kind=$(show_field "$show" hold_kind)
  [ "$hold_kind" = captain ] \
    || fail "backlog item $id was never held for the captain; repair records a captain decision only on a captain hold"
  state=$(show_field "$show" state)
  hold_body=$(show_field "$show" body)
  if [ "$state" = "done" ] && body_has_resolution_record "$hold_body"; then
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf 'repaired: %s\n' "$id"
    return 0
  fi
  [ "$state" = "done" ] \
    || fail "captain hold $id is still open (state=$state); use resolve or decline to close it with the captain's decision"
  body=$(resolution_body repaired "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  show=$(task_show "$id") || fail "captain decision $id disappeared while recording the repair"
  [ "$(show_field "$show" state)" = "done" ] || fail "repairing $id reopened a closed captain decision"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'repaired: %s\n' "$id"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  decline) shift; command_decline "$@" ;;
  repair) shift; command_repair "$@" ;;
  preserve-question) shift; command_preserve_question "$@" ;;
  open-questions) shift; command_open_questions "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

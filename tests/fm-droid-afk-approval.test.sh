#!/usr/bin/env bash
# Behavioral contract for Droid's AFK AskUser deferral guard, the owner-bearing
# question binding it requires, and the existing decision and return owners it
# files through.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-droid-afk-askuser-check.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"
RETURN="$ROOT/bin/fm-afk-return.sh"
TMP_ROOT=$(fm_test_tmproot fm-droid-afk-approval)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A primary home with a real backlog, so questions reach the genuine captain-hold
# and status-decision owners rather than a test double of them.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/bin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '# fixture\n' > "$home/AGENTS.md"
  git -C "$home" init -q
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

seed_task() {  # <home> <id> [status-line...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=synthetic:$id" "kind=ship"
  : > "$home/state/$id.status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.status"; done
}

ask() {  # <home> <questionnaire>; stdout/stderr land in <home>/out and <home>/err
  local home=$1 questionnaire=$2 rc=0
  : > "$home/out"
  : > "$home/err"
  jq -n --arg q "$questionnaire" \
    '{hook_event_name:"PreToolUse",tool_name:"AskUser",tool_input:{questionnaire:$q}}' \
    | PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$CHECK" > "$home/out" 2> "$home/err" || rc=$?
  return "$rc"
}

holds() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$HOLD" "$@"
}

run_return() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$RETURN" 2>&1
}

deny_message() {  # <home>
  jq -r '.systemMessage' "$1/err"
}

assert_denied() {  # <rc> <home> <label>
  local rc=$1 home=$2 label=$3
  [ "$rc" -eq 2 ] || fail "$label must be denied with exit 2, got $rc"
  [ ! -s "$home/out" ] || fail "$label wrote stdout: $(cat "$home/out")"
  jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse" and
    .hookSpecificOutput.permissionDecision == "deny" and
    (.systemMessage | contains("denied, not answered")) and
    (.systemMessage | contains("continue every independently authorized action")) and
    (.systemMessage | contains("operationally prefixed input is not the captain returning")) and
    (.systemMessage | contains("grants no additional approval"))
  ' "$home/err" >/dev/null || fail "$label lost its timing or authority contract: $(cat "$home/err")"
}

# The reported defect: an approval question asked interactively during away mode.
# The question must instead be denied and filed with the owner its binding names,
# while unrelated authorized progress continues untouched.
test_existing_status_owner_receives_the_deferred_question() {
  local home rc=0 folded
  home=$(make_home status-owner)
  seed_task "$home" review \
    'needs-decision [key=helper-versions]: restrict helper equality to MAS or keep paused' \
    'working: independently authorized review evidence continues'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[topic] Descriptive helper topic that names no owner
[option] Approve
[option] Keep paused' || rc=$?
  assert_denied "$rc" "$home" "an away-mode approval question"
  assert_contains "$(deny_message "$home")" 'question 1 status review/helper-versions' \
    'the deferred question was not filed with its bound status owner'

  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  folded=$(status_open_decisions "$home/state/review.status")
  [ "$(printf '%s\n' "$folded" | grep -c '^helper-versions	')" -eq 1 ] \
    || fail "the bound decision must stay exactly one open identity: $folded"
  assert_contains "$(cat "$home/state/review.status")" 'working: independently authorized review evidence continues' \
    'deferral discarded unrelated authorized progress'
  assert_not_contains "$(cat "$home/state/review.status")" 'resolved [key=' \
    'deferral automatically approved a decision'
  pass "an away-mode approval question is denied and filed with the status owner its binding names"
}

# A descriptive topic must never become an owner, and independently authorized
# work after the denial must not evict the unanswered question.
test_repeat_notifications_and_authorized_progress_keep_one_identity() {
  local home rc=0 before after folded
  home=$(make_home repeat-durability)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  local q='1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve
[option] Keep paused'

  ask "$home" "$q" || rc=$?
  [ "$rc" -eq 2 ] || fail "the first away-mode attempt must be denied"
  before=$(cksum < "$home/state/review.status")

  # A fresh guard process with the same disk state is all a restarted or compacted
  # session can recover from, so an exact replay must change nothing.
  rc=0
  ask "$home" "$q" || rc=$?
  [ "$rc" -eq 2 ] || fail "a repeated away-mode notification must still deny AskUser"
  after=$(cksum < "$home/state/review.status")
  [ "$before" = "$after" ] || fail "an exact replay rewrote the durable decision owner"

  printf 'working: authorized follow-up landed while the captain was away\n' >> "$home/state/review.status"
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  folded=$(status_open_decisions "$home/state/review.status")
  assert_contains "$folded" 'helper-versions	needs-decision' \
    'authorized progress after the denial erased the unanswered question'
  pass "repeat notifications are idempotent and authorized progress never evicts the deferred question"
}

# One decision identity, several attempted wordings: every attempt survives.
test_reworded_attempt_is_kept_as_another_variant() {
  local home rc=0 variants
  home=$(make_home variants)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve' || rc=$?
  rc=0
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds only?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the reworded attempt must still be denied"

  variants=$(holds "$home" open-questions \
    | awk -F '\t' '$1 == "chunk" { print $2 "/" $3 }' | sort -u | wc -l | tr -d ' ')
  [ "$variants" -eq 2 ] || fail "both attempted wordings must survive as variants, saw $variants"
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  [ "$(status_open_decisions "$home/state/review.status" | grep -c '^helper-versions	')" -eq 1 ] \
    || fail "two variants must remain one unresolved decision identity"
  pass "a reworded attempt is retained as another variant of one decision identity"
}

test_identical_questions_are_preserved_for_each_status_key() {
  local home rc=0 listing
  home=$(make_home identical-status-evidence)
  seed_task "$home" review \
    'needs-decision [key=first-choice]: choose the first policy' \
    'needs-decision [key=second-choice]: choose the second policy'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Apply the shared policy?
[firstmate-decision origin=review key=first-choice state=existing]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the first identical question must be denied"
  rc=0
  ask "$home" '1. [question] Apply the shared policy?
[firstmate-decision origin=review key=second-choice state=existing]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the second identical question must be denied"

  listing=$(holds "$home" open-questions --render)
  assert_contains "$listing" '[key=first-choice] owner=status' \
    'the first key lost its identical deferred question'
  assert_contains "$listing" '[key=second-choice] owner=status' \
    'the second key lost its identical deferred question'
  [ "$(printf '%s\n' "$listing" | grep -Fxc '1. [question] Apply the shared policy?')" -eq 2 ] \
    || fail "identical question evidence was not preserved once for each decision key"
  pass "identical status-owned questions retain evidence under each decision key"
}

# An unseeded review or merge question has no prior record, so it becomes an
# ordinary captain hold under its real origin - never a synthetic ledger.
test_unseeded_binding_creates_an_ordinary_captain_hold() {
  local home rc=0 id show
  home=$(make_home unseeded)
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Merge PR 123 after its required checks are green?
[firstmate-decision origin=release key=merge-pr-123 state=unseeded]
[option] Approve merge
[option] Do not merge' || rc=$?
  assert_denied "$rc" "$home" "an unseeded merge approval question"

  id=release-decision-merge-pr-123
  show=$( (cd "$home" && tasks-axi show "$id" --full) ) || fail "no captain hold was created for the unseeded question"
  assert_contains "$show" 'kind: captain' "the unseeded question did not become a captain decision"
  assert_contains "$show" 'held: yes' "the created captain decision is not actively held"
  assert_absent "$home/state/droid-afk-approval.status" "a synthetic question ledger was created"
  assert_absent "$home/state/$id.meta" "a dummy task metadata surrogate was created"
  pass "an unseeded binding creates an ordinary captain hold under its real origin"
}

# The R4 defect: once `complete` transfers a key to its hold, the status fold no
# longer matches it. Reopening status there would let fm-send close a duplicate
# and leave the authoritative hold unanswered forever.
test_transferred_hold_wins_and_status_is_never_reopened() {
  local home rc=0 status_text
  home=$(make_home transferred)
  seed_task "$home" review 'needs-decision [key=route-choice]: north or south'
  holds "$home" hold review route-choice --title 'Choose the route' --reason 'captain decision pending' >/dev/null \
    || fail "could not seed the captain hold"
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Route north or south?
[firstmate-decision origin=review key=route-choice state=existing]
[option] North
[option] South' || rc=$?
  assert_denied "$rc" "$home" "a question whose decision already moved to a captain hold"
  assert_contains "$(deny_message "$home")" 'question 1 hold review-decision-route-choice' \
    'the transferred decision was not filed with its captain hold'

  status_text=$(cat "$home/state/review.status")
  assert_contains "$status_text" 'captain-held [key=route-choice]: tracked by review-decision-route-choice' \
    'the interrupted status-to-hold transfer was not finished'
  [ "$(printf '%s\n' "$status_text" | grep -c '^needs-decision \[key=route-choice\]')" -eq 1 ] \
    || fail "status was reopened for a key its captain hold already owns: $status_text"
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  [ -z "$(status_open_decisions "$home/state/review.status")" ] \
    || fail "a duplicate status decision survives beside the authoritative hold"
  pass "an active captain hold wins and the status ledger is never reopened behind it"
}

test_status_question_moves_to_hold_before_transfer_closes() {
  local home rc=0 listing
  home=$(make_home transfer-evidence)
  seed_task "$home" review 'needs-decision [key=route-choice]: north or south'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Route north or south?
[firstmate-decision origin=review key=route-choice state=existing]
[option] North
[option] South' || rc=$?
  [ "$rc" -eq 2 ] || fail "the status-owned question must be denied"
  holds "$home" hold review route-choice --title 'Choose the route' --reason 'captain decision pending' >/dev/null \
    || fail "could not seed the captain hold"
  holds "$home" complete review route-choice >/dev/null \
    || fail "could not transfer the status decision to its hold"

  listing=$(holds "$home" open-questions --render)
  assert_contains "$listing" '[key=route-choice] owner=hold' \
    'the transferred decision did not become hold-owned'
  assert_contains "$listing" '1. [question] Route north or south?' \
    'the status-owned question disappeared during transfer'
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  [ -z "$(status_open_decisions "$home/state/review.status")" ] \
    || fail "the status decision stayed open after its evidence reached the hold"
  pass "status question evidence reaches the hold before transfer closes its key"
}

test_open_questions_reports_incomplete_hold_enumeration() {
  local home out rc=0
  home=$(make_home incomplete-hold-enumeration)

  out=$(PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=0 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$HOLD" open-questions --render 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "open-questions reported success without enumerating captain holds"
  assert_contains "$out" 'compatible tasks-axi is unavailable; captain-decision holds were not read' \
    'incomplete hold enumeration did not report its missing owner surface'
  pass "open-questions reports incomplete captain-hold enumeration"
}

# Ownership must come from the caller. Anything less is rejected loudly rather
# than guessed from a topic, the question text, or the session.
test_unbound_and_malformed_questions_are_rejected_without_mutation() {
  local home rc=0 before
  home=$(make_home rejection)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  before=$(cksum < "$home/state/review.status")

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[topic] Descriptive topic that is not an owner
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question with no owner binding"
  assert_contains "$(deny_message "$home")" 'CONTRACT VIOLATION, not filed' \
    'an unbound question was not rejected explicitly'
  assert_contains "$(deny_message "$home")" 'has no [firstmate-decision origin=' \
    'the rejection did not name the missing requirement'

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision key=malformed-route state=existing]
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question whose binding omits its origin"
  assert_contains "$(deny_message "$home")" 'has no valid origin=' \
    'the malformed binding rejection did not name the missing origin'

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision origin=review origin=release key=helper-versions state=existing]
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question whose binding repeats its origin"
  assert_contains "$(deny_message "$home")" 'require exactly one origin=' \
    'the repeated-field rejection did not name the strict binding requirement'
  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "a repeated binding field mutated the durable decision owner"

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision origin=review key=helper-versions state=existing extra=token]
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question whose binding carries an extra token"
  assert_contains "$(deny_message "$home")" 'with no extra tokens' \
    'the extra-token rejection did not name the strict binding requirement'
  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "an extra binding token mutated the durable decision owner"

  rc=0
  ask "$home" '1. [question] Stale binding?
[firstmate-decision origin=review key=never-seeded state=existing]
[option] Yes' || rc=$?
  assert_denied "$rc" "$home" "a binding claiming an owner that does not exist"
  assert_contains "$(deny_message "$home")" 'OWNER FAULT, not filed' \
    'a stale existing binding was not surfaced as an owner fault'

  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "a rejected question mutated the durable decision owner"
  [ "$( (cd "$home" && tasks-axi list --state held --kind captain) | grep -c '^  ' || true)" -eq 0 ] \
    || fail "a rejected question invented a captain hold"
  pass "unbound, malformed, and stale bindings are rejected loudly and mutate nothing"
}

# Framing text before the first numbered question is not itself a question, so it
# must not be rejected for carrying no binding or shift the question ordinals.
test_leading_preamble_is_not_mistaken_for_a_question() {
  local home rc=0
  home=$(make_home preamble)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  ask "$home" 'Here is some framing text before the questions.
1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve' || rc=$?
  assert_denied "$rc" "$home" "a questionnaire with leading preamble"
  assert_not_contains "$(deny_message "$home")" 'CONTRACT VIOLATION' \
    'leading preamble was mistaken for a question with no binding'
  assert_contains "$(deny_message "$home")" 'question 1 status review/helper-versions' \
    'preamble shifted the question ordinal away from its owner'
  pass "leading preamble is not mistaken for an unbound question"
}

# One questionnaire, two origins: the first block must not capture the second.
test_multi_origin_questionnaire_reaches_each_owner() {
  local home rc=0 message
  home=$(make_home multi-origin)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[topic] Descriptive helper topic
[option] Approve
2. [question] Merge PR 123 after its required checks are green?
[firstmate-decision origin=release key=derive state=unseeded]
[option] Approve merge
[option] Do not merge' || rc=$?
  assert_denied "$rc" "$home" "a two-origin questionnaire"
  message=$(deny_message "$home")
  assert_contains "$message" 'question 1 status review/helper-versions' \
    'the status-owned block did not reach its own owner'
  assert_contains "$message" 'question 2 hold release-decision-droid-askuser-' \
    'the unseeded block did not reach its own origin'
  pass "each block of a multi-origin questionnaire reaches its own bound owner"
}

# The captain must get every deferred question back, byte for byte, at return.
test_return_presents_every_question_losslessly() {
  local home rc=0 listing long expected actual item
  home=$(make_home return-listing)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  long=$(awk 'BEGIN { for (i = 0; i < 120; i++) printf "long café segment %d ", i }')
  ask "$home" "1. [question] Limit helper-version equality checks to MAS builds for café α → β 🚀?
[firstmate-decision origin=review key=helper-versions state=existing]
[topic] Descriptive café topic
[option] Approve
[option] Keep paused
2. [question] $long
[firstmate-decision origin=release key=long-question state=unseeded]
[option] Approve" || rc=$?
  [ "$rc" -eq 2 ] || fail "the away-mode attempt must be denied before the return case"

  # Every chunk of every variant reassembles to the exact stored question.
  item=$(holds "$home" open-questions | awk -F '\t' '$1 == "decision" && $4 == "long-question" { print $2 }')
  [ -n "$item" ] || fail "the long question is missing from the outstanding-question projection"
  actual=$(holds "$home" open-questions \
    | awk -F '\t' -v it="$item" '$1 == "chunk" && $2 == it { printf "%s", $6 }' \
    | base64 --decode)
  expected=$(printf '2. [question] %s\n[option] Approve' "$long")
  [ "$actual" = "$expected" ] || fail "a chunked question did not reassemble to its stored bytes"
  holds "$home" open-questions \
    | awk -F '\t' -v it="$item" '$1 == "chunk" && $2 == it { if (length($6) > 800) bad = 1 } END { exit bad ? 1 : 0 }' \
    || fail "a return chunk exceeded the 800-character bound"

  listing=$(run_return "$home") || fail "the away-mode return catch-up failed"
  assert_contains "$listing" 'outstanding decision' 'return catch-up presented no outstanding decision'
  assert_contains "$listing" 'café α → β 🚀' 'return catch-up lost the Unicode question text'
  assert_contains "$listing" '[key=helper-versions] owner=status' \
    'return catch-up omitted the status-owned question'
  assert_contains "$listing" '[key=long-question] owner=hold' \
    'return catch-up omitted the hold-owned question'
  assert_contains "$listing" 'long café segment 119' 'return catch-up truncated a long question'
  assert_not_contains "$listing" '[firstmate-decision origin=' \
    'return catch-up showed the transport binding line to the captain'
  pass "return catch-up presents every deferred question, including Unicode and over-long ones, without omission"
}

# Returning must restore native questioning without answering anything, and the
# guard must stay inert for linked workers throughout.
test_return_restores_askuser_without_approving_anything() {
  local home rc=0 child
  home=$(make_home return-restores)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve
[option] Keep paused' || rc=$?
  [ "$rc" -eq 2 ] || fail "the away-mode attempt must be denied"

  run_return "$home" >/dev/null || fail "the away-mode return catch-up failed"
  assert_absent "$home/state/.afk" "the return did not clear away mode"

  rc=0
  ask "$home" '1. [question] Anything at all?
[option] Yes' || rc=$?
  [ "$rc" -eq 0 ] || fail "AskUser must be available after the return, got exit $rc"
  [ ! -s "$home/out" ] && [ ! -s "$home/err" ] || fail "the post-return allow wrote output"

  assert_not_contains "$(cat "$home/state/review.status")" 'resolved [key=' \
    'the return automatically resolved a deferred decision'
  assert_contains "$( (cd "$home" && tasks-axi show review-decision-helper-versions --full) 2>&1 || true)" \
    'not found' 'the deferral closed or invented a hold for a status-owned decision'

  fm_git_identity "$home"
  git -C "$home" add AGENTS.md
  git -C "$home" commit -qm fixture
  child="$TMP_ROOT/linked-child"
  git -C "$home" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/state" "$child/fakebin"
  printf '# fixture\n' > "$child/AGENTS.md"
  date +%s > "$child/state/.afk"
  rc=0
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"AskUser","tool_input":{"questionnaire":"1. [question] anything?"}}' \
    | FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
      "$CHECK" > "$child/out" 2> "$child/err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the guard must stay inert in a linked task worktree, got exit $rc"
  [ ! -s "$child/out" ] && [ ! -s "$child/err" ] || fail "the linked-worktree no-op wrote output"
  pass "a real return restores AskUser, approves nothing, and leaves linked workers untouched"
}

# Answering a returned question must close it through the owner's own existing
# close path, and only then may it leave the outstanding listing.
test_answers_close_through_the_existing_owner_paths() {
  local home rc=0 answer listing
  home=$(make_home answer-closure)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve
2. [question] Merge PR 123 after its required checks are green?
[firstmate-decision origin=release key=merge-pr-123 state=unseeded]
[option] Approve merge' || rc=$?
  [ "$rc" -eq 2 ] || fail "the away-mode attempt must be denied"

  # The status owner closes on its own exact resolved transition, the one
  # bin/fm-send.sh --resolve-key appends after it confirms delivery.
  printf 'resolved [key=helper-versions]: captain approved the MAS-only check\n' \
    >> "$home/state/review.status"

  # The hold owner closes through the existing keyed-answer intake.
  answer="$home/answer.tsv"
  printf 'merge-pr-123\tcaptain approved the merge once checks are green\treturn\n' > "$answer"
  holds "$home" answers release --source return < "$answer" >/dev/null \
    || fail "the existing keyed-answer intake could not close the returned hold"

  listing=$(holds "$home" open-questions --render)
  assert_not_contains "$listing" 'helper-versions' \
    'an answered status question stayed in the outstanding listing'
  assert_not_contains "$listing" 'merge-pr-123' \
    'an answered captain hold stayed in the outstanding listing'
  assert_contains "$( (cd "$home" && tasks-axi show release-decision-merge-pr-123 --full) )" 'state: done' \
    'the keyed answer did not durably close the captain hold'
  pass "answers close deferred questions through the existing status and captain-hold paths"
}

test_existing_status_owner_receives_the_deferred_question
test_repeat_notifications_and_authorized_progress_keep_one_identity
test_reworded_attempt_is_kept_as_another_variant
test_identical_questions_are_preserved_for_each_status_key
test_unseeded_binding_creates_an_ordinary_captain_hold
test_transferred_hold_wins_and_status_is_never_reopened
test_status_question_moves_to_hold_before_transfer_closes
test_open_questions_reports_incomplete_hold_enumeration
test_unbound_and_malformed_questions_are_rejected_without_mutation
test_leading_preamble_is_not_mistaken_for_a_question
test_multi_origin_questionnaire_reaches_each_owner
test_return_presents_every_question_losslessly
test_return_restores_askuser_without_approving_anything
test_answers_close_through_the_existing_owner_paths

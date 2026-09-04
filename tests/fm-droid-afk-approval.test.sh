#!/usr/bin/env bash
# Behavioral contract for Droid's AFK AskUser deferral guard and the existing
# durable decision/return owners it protects.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-droid-afk-askuser-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-droid-afk-approval)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_check() {  # <root> <state>
  local root=$1 state=$2 rc=0
  : > "$OUT"
  : > "$ERR"
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"AskUser","tool_input":{"questionnaire":"1. [question] Approve the bounded correction?\\n[topic] Bounded-correction\\n[option] Approve\\n[option] Keep parked"}}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$root" FM_STATE_OVERRIDE="$state" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

test_afk_denies_without_answering_and_preserves_repeats() {
  local rc=0 before after folded
  cat > "$STATE/review.meta" <<'EOF'
window=synthetic:review
kind=ship
EOF
  cat > "$STATE/review.status" <<'EOF'
needs-decision [key=helper-versions]: restrict helper equality to MAS or keep paused
needs-decision [key=all-day-recurrence]: apply bounded seeking or keep paused
working: independently authorized review evidence continues
EOF
  date +%s > "$STATE/.afk"
  before=$(cksum "$STATE/review.status")

  run_check "$PRIMARY" "$STATE" || rc=$?
  [ "$rc" -eq 2 ] || fail "Droid AskUser while AFK must be denied with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "Droid AFK deny wrote stdout: $(cat "$OUT")"
  jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse" and
    .hookSpecificOutput.permissionDecision == "deny" and
    (.systemMessage | contains("denied, not answered")) and
    (.systemMessage | contains("continue every independently authorized action")) and
    (.systemMessage | contains("operationally prefixed input is not the captain returning")) and
    (.systemMessage | contains("grants no additional approval"))
  ' "$ERR" >/dev/null || fail "Droid AFK deny lost its timing or authority contract: $(cat "$ERR")"

  # Invoke a fresh guard process with the same disk state, matching the only
  # state the hook can recover after a context compaction or session restart.
  rc=0
  run_check "$PRIMARY" "$STATE" || rc=$?
  [ "$rc" -eq 2 ] || fail "repeated AFK notification must still deny AskUser without approval"
  after=$(cksum "$STATE/review.status")
  [ "$before" = "$after" ] || fail "repeated AskUser denial changed the durable decision source"

  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  folded=$(status_open_decisions "$STATE/review.status")
  assert_contains "$folded" $'helper-versions\tneeds-decision\trestrict helper equality to MAS or keep paused' "first keyed approval disappeared after repeat denial"
  assert_contains "$folded" $'all-day-recurrence\tneeds-decision\tapply bounded seeking or keep paused' "second keyed approval disappeared after repeat denial"
  assert_contains "$(cat "$STATE/review.status")" 'working: independently authorized review evidence continues' "AFK question deferral discarded unrelated authorized progress"
  assert_not_contains "$(cat "$STATE/review.status")" 'resolved [key=' "AFK question deferral automatically approved a decision"
  pass "Droid AFK denies AskUser without answering, preserves keyed decisions across fresh-process repeats, and leaves authorized progress intact"
}

test_return_restores_askuser_and_linked_workers_stay_inert() {
  local child="$TMP_ROOT/child" rc=0
  rm -f "$STATE/.afk"
  run_check "$PRIMARY" "$STATE" || rc=$?
  [ "$rc" -eq 0 ] || fail "AskUser must be available after AFK return, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "post-return AskUser allow wrote output"

  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  date +%s > "$child/state/.afk"
  rc=0
  run_check "$child" "$child/state" || rc=$?
  [ "$rc" -eq 0 ] || fail "Droid AskUser guard must be inert in a linked task worktree, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "linked-worktree no-op wrote output"
  pass "real return restores Droid AskUser and the primary-only guard leaves linked workers unchanged"
}

test_afk_denies_without_answering_and_preserves_repeats
test_return_restores_askuser_and_linked_workers_stay_inert

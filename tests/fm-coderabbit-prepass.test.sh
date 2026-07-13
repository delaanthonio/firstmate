#!/usr/bin/env bash
# Behavior test for the CodeRabbit pre-pass in no-mistakes ship briefs
# (fm-brief.sh). The pre-pass must run before /no-mistakes, must not claim to
# replace the no-mistakes review gate, and must surface an unauthenticated
# CodeRabbit as a captain setup step.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-coderabbit-prepass)

test_no_mistakes_brief_has_coderabbit_prepass() {
  local home="$TMP_ROOT/home" id=cr-prepass-a1 out brief
  mkdir -p "$home/data"
  # No data/projects.md -> fm-project-mode.sh defaults the repo to no-mistakes.
  out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" "$BRIEF" "$id" widget 2>&1) || fail "fm-brief.sh failed: $out"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "coderabbit review" "$brief" "no-mistakes brief is missing the CodeRabbit pre-pass"
  assert_grep "does NOT replace the no-mistakes review gate" "$brief" "pre-pass must not claim to replace the gate"
  assert_grep "coderabbit auth login" "$brief" "brief must surface the captain auth step"
  assert_grep "/no-mistakes" "$brief" "brief must still drive /no-mistakes after the pre-pass"
  pass "fm-brief.sh: no-mistakes brief runs CodeRabbit before /no-mistakes without replacing the gate"
}

test_no_mistakes_brief_has_coderabbit_prepass

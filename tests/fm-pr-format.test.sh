#!/usr/bin/env bash
# Behavior tests for fm-pr-format.sh - the one-per-PR readability reformat.
#
# The GitHub CLI and the rewrite agent are both injected (FM_PR_FORMAT_GH /
# FM_PR_FORMAT_AGENT), so the real fm-pr-format.sh runs end to end with no
# network and no LLM: a fake gh serves a body fixture and records the edited
# body; a fake agent returns deterministic markdown. FM_ROOT points at a temp
# dir holding an fm-guard.sh stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORMAT="$ROOT/bin/fm-pr-format.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-format)
PR_URL="https://github.com/acme/widget/pull/7"

mkdir -p "$TMP_ROOT/root/bin"
cat > "$TMP_ROOT/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/root/bin/fm-guard.sh"

# Fake gh: `pr view ... -q .title|.body` serves fixtures; `pr edit --body-file`
# records the new body to FAKE_EDITED.
cat > "$TMP_ROOT/gh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  view) case "$*" in *"-q .title"*) printf 'Add the widget\n';; *"-q .body"*) cat "$FAKE_BODY";; esac ;;
  edit) f=""; while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && f="$2"; shift; done; cat "$f" > "$FAKE_EDITED" ;;
esac
SH
chmod +x "$TMP_ROOT/gh"

# Fake agents.
cat > "$TMP_ROOT/agent-good" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '```markdown\n\n## Summary\n\n- Adds the widget\n- Wires it in\n\nDetails: https://example.com/x\n\n```\n'
SH
cat > "$TMP_ROOT/agent-tiny" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'x\n'
SH
cat > "$TMP_ROOT/agent-fail" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 3
SH
chmod +x "$TMP_ROOT/agent-good" "$TMP_ROOT/agent-tiny" "$TMP_ROOT/agent-fail"

export FAKE_BODY="$TMP_ROOT/body.txt"
export FAKE_EDITED="$TMP_ROOT/edited.txt"

run_format() {
  local agent=$1 url=$2
  rm -f "$FAKE_EDITED"
  FM_ROOT_OVERRIDE="$TMP_ROOT/root" \
    FM_PR_FORMAT_GH="$TMP_ROOT/gh" \
    FM_PR_FORMAT_AGENT="$TMP_ROOT/$agent" \
    "$FORMAT" "$url" 2>&1
}

test_reformats_dense_body() {
  printf 'intent: add widget. it does X and Y. see https://example.com/x for details.\n' > "$FAKE_BODY"
  local out status edited
  out=$(run_format agent-good "$PR_URL"); status=$?
  expect_code 0 "$status" "reformat happy path"
  assert_contains "$out" "reformatted: PR $PR_URL" "did not report the reformat"
  assert_present "$FAKE_EDITED" "did not edit the PR body"
  edited=$(cat "$FAKE_EDITED")
  assert_contains "$edited" "## Summary" "rewritten body lost its structure"
  assert_contains "$edited" "https://example.com/x" "rewritten body dropped a link"
  assert_not_contains "$edited" '```markdown' "wrapping code fence was not stripped"
  assert_contains "$edited" "<!-- fm-pr-format -->" "idempotency marker was not appended"
  pass "fm-pr-format: rewrites a dense body into structured markdown, strips fence, appends marker"
}

test_idempotent_when_marker_present() {
  printf 'already clean\n\n<!-- fm-pr-format -->\n' > "$FAKE_BODY"
  local out status
  out=$(run_format agent-good "$PR_URL"); status=$?
  expect_code 0 "$status" "idempotent run exits 0"
  assert_contains "$out" "already reformatted" "did not detect the marker"
  assert_absent "$FAKE_EDITED" "must not re-edit a body that already carries the marker"
  pass "fm-pr-format: one reformat per PR (marker makes it idempotent)"
}

test_skips_empty_body() {
  printf '   \n' > "$FAKE_BODY"
  local out status
  out=$(run_format agent-good "$PR_URL"); status=$?
  expect_code 0 "$status" "empty body exits 0"
  assert_contains "$out" "empty body" "did not skip the empty body"
  assert_absent "$FAKE_EDITED" "must not edit when there is nothing to reformat"
  pass "fm-pr-format: skips an empty body"
}

test_content_loss_guard() {
  printf 'A long original body with lots of important content and links https://example.com that must survive a reformat.\n' > "$FAKE_BODY"
  local out status
  out=$(run_format agent-tiny "$PR_URL"); status=$?
  expect_code 1 "$status" "content-loss guard must fail"
  assert_contains "$out" "content loss" "did not flag suspected content loss"
  assert_absent "$FAKE_EDITED" "must leave the body unchanged on suspected content loss"
  pass "fm-pr-format: aborts (no edit) when the rewrite looks like content loss"
}

test_agent_failure_leaves_body() {
  printf 'A real body that should be preserved when the agent dies.\n' > "$FAKE_BODY"
  local out status
  out=$(run_format agent-fail "$PR_URL"); status=$?
  expect_code 1 "$status" "agent failure must fail"
  assert_contains "$out" "agent failed" "did not report the agent failure"
  assert_absent "$FAKE_EDITED" "must leave the body unchanged when the agent fails"
  pass "fm-pr-format: leaves the body untouched when the rewrite agent fails"
}

test_rejects_non_pr_url() {
  local out status
  out=$(run_format agent-good "not-a-pr-url"); status=$?
  expect_code 1 "$status" "bad URL must fail"
  assert_contains "$out" "not a GitHub PR URL" "did not reject the bad URL"
  pass "fm-pr-format: rejects a non-PR URL"
}

test_reformats_dense_body
test_idempotent_when_marker_present
test_skips_empty_body
test_content_loss_guard
test_agent_failure_leaves_body
test_rejects_non_pr_url

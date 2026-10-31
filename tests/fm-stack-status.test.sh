#!/usr/bin/env bash
# tests/fm-stack-status.test.sh - stack grouping and status rendering for
# bin/fm-stack-status.sh.
#
# The grouping contract is the heart of the script: open PRs whose base
# branch equals another open PR's head branch form one stack, ordered base to
# top, with merged ancestors reported as an oldest-first floor matched by
# branch name. A base matching no other PR is its own one-member stack. This
# suite drives the grouping function directly with fixture records and drives
# the script end to end through a fake gh, so nothing here touches a network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-stack-status-lib.sh
. "$ROOT/bin/fm-stack-status-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stack-status)
FIXTURES=$TMP_ROOT/fixtures
mkdir -p "$FIXTURES"

# --- check-rollup summaries --------------------------------------------------

ROLLUP_GREEN='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"SUCCESS"}]'
ROLLUP_MIXED='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","state":"PENDING"}]'
ROLLUP_RUNNING='[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}]'
ROLLUP_EMPTY='[]'

assert_equals "2/2 green" "$(fm_stack_checks_summary "$ROLLUP_GREEN")" \
  "an all-green rollup summarizes as 2/2 green"
assert_equals "1/3 green 1 failed 1 pending" "$(fm_stack_checks_summary "$ROLLUP_MIXED")" \
  "a mixed rollup counts green, failed, and pending checks"
assert_equals "0/1 green 1 pending" "$(fm_stack_checks_summary "$ROLLUP_RUNNING")" \
  "a still-running check counts pending, not green"
assert_equals "none" "$(fm_stack_checks_summary "$ROLLUP_EMPTY")" \
  "an empty rollup summarizes as none"
assert_equals "none" "$(fm_stack_checks_summary "null")" \
  "an absent rollup summarizes as none"
assert_equals "none" "$(fm_stack_checks_summary "")" \
  "an empty-string rollup summarizes as none"
pass "check-rollup summaries count green, failed, and pending checks"

# --- merge-state classification ----------------------------------------------

assert_equals clean "$(fm_stack_merge_state false MERGEABLE CLEAN)" \
  "a clean mergeable PR reports clean"
assert_equals clean "$(fm_stack_merge_state false MERGEABLE HAS_HOOKS)" \
  "a PR with hooks reports clean"
assert_equals dirty "$(fm_stack_merge_state false CONFLICTING CLEAN)" \
  "a conflicting mergeable read reports dirty"
assert_equals dirty "$(fm_stack_merge_state false MERGEABLE DIRTY)" \
  "a dirty merge state reports dirty"
assert_equals blocked "$(fm_stack_merge_state false MERGEABLE BLOCKED)" \
  "a blocked merge state reports blocked"
assert_equals blocked "$(fm_stack_merge_state false MERGEABLE UNSTABLE)" \
  "a failing-check (UNSTABLE) merge state reports blocked"
assert_equals blocked "$(fm_stack_merge_state false MERGEABLE BEHIND)" \
  "a behind-base merge state reports blocked"
assert_equals draft "$(fm_stack_merge_state true MERGEABLE CLEAN)" \
  "a draft PR reports draft regardless of the forge state"
assert_equals unknown "$(fm_stack_merge_state false UNKNOWN UNKNOWN)" \
  "an uncomputed forge verdict reports unknown"
pass "merge fields reduce to draft, dirty, blocked, clean, or unknown"

# --- origin parsing ----------------------------------------------------------

assert_equals "owner/app" "$(fm_stack_repo_of_url 'https://github.com/owner/app.git')" \
  "an https origin parses to owner/name"
assert_equals "owner/app" "$(fm_stack_repo_of_url 'git@github.com:owner/app.git')" \
  "a scp-like ssh origin parses to owner/name"
assert_equals "group/app" "$(fm_stack_repo_of_url 'ssh://git@git.example.com:2222/group/app.git')" \
  "a ported ssh origin keeps the group, not the port"
assert_equals "org/app" "$(fm_stack_repo_of_url 'https://user:token@git.example.com/org/app.git')" \
  "a token-carrying origin keeps the org, not the credential"
fm_stack_repo_of_url 'https://github.com/nope' >/dev/null 2>&1 &&
  fail "a one-segment origin URL must not parse"
fm_stack_repo_of_url 'https://github.com/ow er/app.git' >/dev/null 2>&1 &&
  fail "an owner with a space must not parse"
pass "origin URLs parse to owner/name and junk is refused"

# --- stack grouping ----------------------------------------------------------

# Open record fields: number, head, base, draft, mergeable, mergeStateStatus,
# title, url, rollup. Only the first three matter to grouping.
open_tsv=$FIXTURES/open.tsv
merged_tsv=$FIXTURES/merged.tsv
: > "$open_tsv"
: > "$merged_tsv"
add_open() {
  printf '%s\t%s\t%s\tfalse\tMERGEABLE\tCLEAN\ttitle %s\thttps://example.com/pr/%s\t[]\n' \
    "$1" "$2" "$3" "$1" "$1" >> "$open_tsv"
}
add_merged() {  # <number> <head> <base>, most recent first
  printf '%s\t%s\t%s\tmerged title %s\thttps://example.com/pr/%s\n' \
    "$1" "$2" "$3" "$1" "$1" >> "$merged_tsv"
}

# Stack one hangs on a two-PR merged floor: #10 merged onto main, #11 merged
# onto #10's branch, and open #20 sits on #11's branch with #21 above it.
add_merged 11 step-2 step-1
add_merged 10 step-1 main
add_open 20 step-3 step-2
add_open 21 step-4 step-3
# Stack two is a plain two-member chain off main.
add_open 22 feat-c main
add_open 23 feat-d feat-c
# The orphan's base matches no open PR and no merged PR.
add_open 30 orphan-h release/2.0

groups=$(fm_stack_group "$open_tsv" "$merged_tsv")
assert_contains "$groups" "stack 20 floor 10 11" \
  "the merged-floor stack lists both merged ancestors oldest first"
assert_contains "$groups" "stack 22 floor -" \
  "a chain off an unmerged base reports no floor"
assert_contains "$groups" "stack 30 floor -" \
  "an orphan PR forms its own stack with no floor"
assert_equals 3 "$(printf '%s\n' "$groups" | grep -c '^stack ')" \
  "three stacks are discovered"
pass "stacks group by base/head chains across multi-stack, merged floor, and orphan shapes"

# Member order within a stack is base to top: depth first, then number.
stack20_members=$(printf '%s\n' "$groups" | awk '/^stack 20 /{s=1;next} /^stack /{s=0} s && /^member/ {print $2}')
assert_equals "20
21" "$stack20_members" "the merged-floor stack lists its open members base to top"
pass "members order base to top within each stack"

# A sync PR whose head is the default branch never parents main-targeting
# PRs into one degenerate stack; it stands as its own single-member stack.
add_open 40 main feature-sync
groups_sync=$(fm_stack_group "$open_tsv" "$merged_tsv" main)
assert_contains "$groups_sync" "stack 40 floor -" \
  "a sync PR whose head is the default branch forms its own stack"
sync_stack_members=$(printf '%s\n' "$groups_sync" | awk '/^stack 40 /{s=1;next} /^stack /{s=0} s && /^member/ {print $2}')
assert_equals "40" "$sync_stack_members" \
  "the sync PR's stack holds only the sync PR itself"
pass "a default-branch-headed sync PR never parents main-targeting PRs"

# A merged ancestor chain is matched by branch name, so a reused head branch
# takes the most recent merged PR (the fixture lists it first).
add_merged 99 step-2 step-0
groups_reused=$(fm_stack_group "$open_tsv" "$merged_tsv")
assert_contains "$groups_reused" "stack 20 floor 10 11" \
  "the most recent merged PR wins a reused head branch"
pass "a reused merged head branch resolves to its most recent PR"

# --- end-to-end rendering through a fake gh ---------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ]; then
  case "\$2" in
    *"pulls?state=open"*)
      case "\$2" in
        *"page=1"*) cat '$FIXTURES/e2e-open-rest.json' ;;
        *) printf '[]\n' ;;
      esac
      ;;
    *"pulls?state=closed"*)
      case "\$2" in
        *"page=1"*) cat '$FIXTURES/e2e-closed-rest.json' ;;
        *) printf '[]\n' ;;
      esac
      ;;
    graphql) cat '$FIXTURES/e2e-graphql.json' ;;
    *) printf '[]\n' ;;
  esac
  exit 0
fi
exit 0
SH
chmod +x "$FAKEBIN/gh"

# The end-to-end fixtures mirror the live shapes: the REST pulls listing for
# the inventory, the GraphQL batch for merge details, checks, and queue
# membership (a two-member stack whose bottom builds on a merged floor).
cat > "$FIXTURES/e2e-open-rest.json" <<'JSON'
[{"number":20,"title":"Add y","head":{"ref":"step-3"},"base":{"ref":"step-2"},"draft":false},
 {"number":21,"title":"Fix z","head":{"ref":"step-4"},"base":{"ref":"step-3"},"draft":false}]
JSON
cat > "$FIXTURES/e2e-closed-rest.json" <<'JSON'
[{"number":11,"title":"Add x","head":{"ref":"step-2"},"base":{"ref":"step-1"},"merged_at":"2026-10-30T10:00:00Z"}]
JSON
cat > "$FIXTURES/e2e-graphql.json" <<'JSON'
{"data":{"repository":{"a0":{"number":20,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","mergeQueueEntry":null,"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}}},"a1":{"number":21,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","mergeQueueEntry":{"position":1},"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]}}}}}}
JSON

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r)
assert_contains "$out" "repo: o/r" "the listing names the repository"
assert_contains "$out" "stack 1 (base step-2)" "the stack header names the base branch"
assert_contains "$out" "  #11  Add x | MERGED" "the merged floor is marked visibly"
assert_contains "$out" "  #20  Add y | checks 1/1 green | merge clean" \
  "an open member reports title, checks, and merge state"
assert_contains "$out" "  #21  Fix z | checks 1/2 green 1 failed | merge blocked | queue 1" \
  "a queued member reports its queue position"
pass "the script renders stacks, merged floors, checks, states, and queue membership"

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r 21)
assert_contains "$out" "stack 1 (base step-2)" \
  "scoping to a member PR prints its own stack"
assert_contains "$out" "#20" "the scoped stack keeps the bottom member"
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r 20)
assert_not_contains "$out" "#30" \
  "scoping omits unrelated stacks"
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r 11)
assert_contains "$out" "MERGED" \
  "scoping to a merged floor PR still prints its stack"
pass "a PR argument scopes the listing to that PR's own stack"

printf '[]\n' > "$FIXTURES/e2e-open-rest.json"
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r)
assert_contains "$out" "no open pull requests in o/r" \
  "a repository with no open PRs says so"
code=0
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r 20) || code=$?
assert_contains "$out" "no open pull requests in o/r" \
  "scoping in an empty repository answers the same no-open-PRs message"
assert_equals 0 "$code" "an empty repository is a clean zero-exit answer"
pass "an empty repository degrades to a plain no-open-PRs message"

# --- large repository: per-PR details bounded to multi-PR chains --------------

# Over 100 open orphans plus one two-member chain: details are fetched only
# for the chain, so orphan singletons render as bare titles.
{
  printf '['
  sep=""
  for i in $(seq 1 101); do
    printf '%s{"number":%d,"title":"orphan %d","head":{"ref":"orphan-%d"},"base":{"ref":"main"},"draft":false}' \
      "$sep" "$i" "$i" "$i"
    sep=","
  done
  printf '%s{"number":200,"title":"Chain top","head":{"ref":"chain-2"},"base":{"ref":"chain-1"},"draft":false}' "$sep"
  printf '%s{"number":201,"title":"Chain above","head":{"ref":"chain-3"},"base":{"ref":"chain-2"},"draft":false}' ","
  printf ']'
} > "$FIXTURES/e2e-open-rest.json"
printf '[]\n' > "$FIXTURES/e2e-closed-rest.json"
cat > "$FIXTURES/e2e-graphql.json" <<'JSON'
{"data":{"repository":{"a0":{"number":200,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","mergeQueueEntry":null,"statusCheckRollup":{"contexts":{"nodes":[]}}},"a1":{"number":201,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","mergeQueueEntry":null,"statusCheckRollup":{"contexts":{"nodes":[]}}}}}}
JSON

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r)
assert_contains "$out" "  #5  orphan 5 | checks - | merge -" \
  "an orphan singleton in a large repository renders without per-PR details"
assert_contains "$out" "  #200  Chain top | checks none | merge clean" \
  "a multi-PR-chain member keeps its per-PR details in a large repository"
assert_contains "$out" "  #201  Chain above | checks none | merge blocked" \
  "the chain top keeps its merge state in a large repository"
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-status.sh" --repo o/r 200)
assert_contains "$out" "  #200  Chain top | checks none | merge clean" \
  "scoping in a large repository fetches the whole stack's details"
assert_not_contains "$out" "#5" \
  "scoping in a large repository omits orphan stacks"
pass "a large repository bounds per-PR details to multi-PR chains and scoped stacks"

echo "ALL TESTS PASSED"

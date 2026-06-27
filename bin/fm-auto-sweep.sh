#!/usr/bin/env bash
# Auto-dispatch ONE focused review-comment sweep for a PR-based ship task, once
# the PR is green and CodeRabbit has reviewed.
#
# Two modes:
#
#   fm-auto-sweep.sh --check <task-id> <pr-url>
#     The detector. Run by the watcher's per-task poll (the line that
#     fm-pr-check.sh adds to state/<id>.check.sh). Honors the watcher's check
#     contract: prints exactly ONE wake line -- "auto-sweep: <id> <url>" -- iff
#     the PR is OPEN, its checks are green, CodeRabbit has posted a review, and
#     at least one unresolved, non-outdated review thread remains to clear.
#     Silent otherwise; fails safe (silent) on any error so a broken poll never
#     crashes the watcher. Stays silent once state/<id>.auto-swept exists, so the
#     sweep is dispatched at most once per PR. Because it stays silent until
#     CodeRabbit has actually reviewed, the watcher's poll cadence IS the "short
#     delay so CodeRabbit can post" -- no sleep is needed, and a not-yet-posted
#     review simply retries on the next sweep.
#
#   fm-auto-sweep.sh <task-id> <pr-url>
#     The spawner. Run by firstmate when it handles the auto-sweep wake. Writes
#     the state/<id>.auto-swept sentinel (so re-wakes never double-spawn),
#     scaffolds a focused single-PR sweep brief, and hands off to fm-spawn.sh.
#     The sweep crewmate ONLY resolves review threads (apply safe fixes, reply,
#     resolve; escalate judgement calls); it never merges and never opens a PR.
#
# Detection uses the GitHub GraphQL reviewThreads query (isResolved=false AND
# isOutdated=false). Like fm-pr-check.sh's merge poll, the poll uses raw `gh`
# (machine-parseable output), not the gh-axi wrapper: gh-axi's `api` is REST-only
# and reformats output, so it cannot run this GraphQL query nor be parsed here.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# GraphQL query for a PR's review threads.
# shellcheck disable=SC2016  # single quotes are deliberate: $owner/$repo/$pr are GraphQL variables, not shell.
REVIEW_THREADS_QUERY='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{id isResolved isOutdated comments(first:1){nodes{author{login}}}}}}}}'

# Parse https://github.com/<owner>/<repo>/pull/<n>[/...|?...] into OWNER/REPO/NUM.
parse_pr_url() {
  local url=$1 rest
  case "$url" in
    https://github.com/*/*/pull/*) ;;
    *) echo "error: not a GitHub PR URL: $url" >&2; return 1 ;;
  esac
  rest=${url#https://github.com/}
  OWNER=${rest%%/*}; rest=${rest#*/}
  REPO=${rest%%/*};  rest=${rest#*/}
  NUM=${rest#pull/}; NUM=${NUM%%/*}; NUM=${NUM%%\?*}
  case "$NUM" in
    ''|*[!0-9]*) echo "error: could not parse PR number from $url" >&2; return 1 ;;
  esac
}

# ---- check mode (invoked by state/<id>.check.sh) ----------------------------
if [ "${1:-}" = --check ]; then
  shift
  ID=${1:?usage: fm-auto-sweep.sh --check <task-id> <pr-url>}
  URL=${2:?usage: fm-auto-sweep.sh --check <task-id> <pr-url>}

  # One sweep per PR: once dispatched, stay silent forever.
  [ -e "$STATE/$ID.auto-swept" ] && exit 0

  parse_pr_url "$URL" 2>/dev/null || exit 0

  # PR must be OPEN with green (no failing, no pending) checks. Any error -> silent.
  info=$(gh pr view "$URL" --json state,statusCheckRollup,reviews,comments 2>/dev/null) || exit 0
  [ -n "$info" ] || exit 0

  green=$(printf '%s' "$info" | jq -r '
    def bad: ["FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"];
    def pend: ["PENDING","QUEUED","IN_PROGRESS","EXPECTED","WAITING","REQUESTED"];
    if .state != "OPEN" then "notopen"
    else
      ([ .statusCheckRollup[]? | (.conclusion // .state // .status // "") ]) as $c
      | if   any($c[]; . as $x | bad  | index($x)) then "failing"
        elif any($c[]; . as $x | pend | index($x)) then "pending"
        else "green" end
    end' 2>/dev/null) || exit 0
  [ "$green" = green ] || exit 0

  # CodeRabbit must have posted a review or comment, so a one-shot sweep does not
  # fire before its threads exist and then never run again.
  cr=$(printf '%s' "$info" | jq -r '
    [ (.reviews[]?.author.login), (.comments[]?.author.login) ]
    | map(select(. != null) | ascii_downcase)
    | map(select(test("coderabbit"))) | length' 2>/dev/null) || exit 0
  case "$cr" in ''|*[!0-9]*) cr=0 ;; esac
  [ "$cr" -gt 0 ] || exit 0

  # At least one unresolved, non-outdated thread not authored by us must remain.
  self=$(gh api user --jq .login 2>/dev/null || true)
  ids=$(gh api graphql \
    -f query="$REVIEW_THREADS_QUERY" \
    -F owner="$OWNER" -F repo="$REPO" -F pr="$NUM" \
    --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .isOutdated==false and (.comments.nodes[0].author.login != \"$self\")) | .id" \
    2>/dev/null) || exit 0
  [ -n "$ids" ] || exit 0

  echo "auto-sweep: $ID $URL"
  exit 0
fi

# ---- spawn mode (invoked by firstmate on the auto-sweep wake) ---------------
ID=${1:?usage: fm-auto-sweep.sh <task-id> <pr-url>}
URL=${2:?usage: fm-auto-sweep.sh <task-id> <pr-url>}
"$FM_ROOT/bin/fm-guard.sh" || true

SENTINEL="$STATE/$ID.auto-swept"
if [ -e "$SENTINEL" ]; then
  echo "already dispatched a review-comment sweep for $ID ($URL); skipping (one per PR)"
  exit 0
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
PROJ=$(grep '^project=' "$META" | cut -d= -f2- | head -1 || true)
[ -n "$PROJ" ] || { echo "error: no project= in $META" >&2; exit 1; }

parse_pr_url "$URL"

# Resolve the PR's real head branch rather than assuming fm/<id>; the sweep works
# on a distinct local branch so it never collides with the original crew's
# worktree, which may still hold fm/<id> checked out until merge+teardown.
BRANCH=$(gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
SELF=$(gh api user --jq .login 2>/dev/null || true)
LOCAL="sweep-$ID"

RID="$ID-sweep"
BRIEF="$DATA/$RID/brief.md"
if [ -e "$BRIEF" ]; then
  echo "error: sweep brief $BRIEF already exists (was a sweep already started?)" >&2
  exit 1
fi
mkdir -p "$DATA/$RID"

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
Clear the open review comments on PR $URL (a focused, single-pass review-comment sweep).
Address every unresolved, non-outdated review thread that is not authored by \`$SELF\` (that is our own identity - skip those). CodeRabbit is the primary reviewer here.

# Setup
You are in a disposable git worktree of $(basename "$PROJ"), at a detached HEAD on a clean default branch.
Work on a distinct local branch so you never collide with the original crew's worktree (which may still hold \`$BRANCH\` checked out):
1. \`git fetch origin "$BRANCH"\`
2. \`git checkout -B "$LOCAL" "origin/$BRANCH"\` (your local branch tracking the PR head)
3. Confirm you are on $LOCAL at origin/$BRANCH before editing.

# Sweep loop (single pass)
1. List the threads to handle (raw \`gh\`, machine-parseable):
   \`\`\`
   gh api graphql -f query='query(\$owner:String!,\$repo:String!,\$pr:Int!){repository(owner:\$owner,name:\$repo){pullRequest(number:\$pr){reviewThreads(first:100){nodes{id isResolved isOutdated comments(first:10){nodes{author{login} body path}}}}}}}' \\
     -F owner=$OWNER -F repo=$REPO -F pr=$NUM \\
     --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .isOutdated==false and (.comments.nodes[0].author.login != "$SELF"))'
   \`\`\`
2. For each such thread:
   - If the comment is a valid, safe code change, apply it in the worktree.
   - If you disagree or it is out of scope, do not change code; explain in your reply.
   - Reply on the thread (use the comment's databaseId / in_reply_to, or the GraphQL \`addPullRequestReviewThreadReply\` mutation) with a one-line note: what you changed, or why you are declining.
   - Resolve the thread: \`gh api graphql -f query='mutation(\$id:ID!){resolveReviewThread(input:{threadId:\$id}){thread{id}}}' -F id=<thread-id>\`
3. Commit your fixes with a clear message and push to the PR branch:
   \`git push origin "HEAD:$BRANCH"\`
   Do NOT merge the PR and do NOT open a new PR.

# Rules
1. Work only on the PR's branch \`$BRANCH\` (via your local \`$LOCAL\`). Never merge; never open a new PR.
2. Stay inside this worktree; the only file you may write outside it is the status file below.
3. Use \`gh\` for the GraphQL calls above (gh-axi cannot run GraphQL); gh-axi is fine for other GitHub ops.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATE/$RID.status\`
   States: working, needs-decision, blocked, done, failed. Report sparingly - each append wakes firstmate.
5. If a thread asks for a product/design decision or a destructive/irreversible change, do not guess:
   append \`needs-decision: {summary}\` and stop. Firstmate will reply.
6. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.

# Definition of done
When every in-scope thread is handled (fixed or declined-with-reply), resolved, and your fixes are pushed to $BRANCH, append \`done: swept review comments on PR $NUM\` to the status file and stop.
A bot may re-review your push and add fresh comments; that is fine - firstmate decides whether any follow-up is warranted. Do not loop here.
EOF

# Mark BEFORE spawning so a coalesced re-wake cannot dispatch a second sweep.
: > "$SENTINEL"

echo "spawning review-comment sweep $RID for PR $URL (branch $BRANCH)"
"$FM_ROOT/bin/fm-spawn.sh" "$RID" "$PROJ"

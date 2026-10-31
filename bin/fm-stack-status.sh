#!/usr/bin/env bash
# fm-stack-status.sh - show the status of every open PR stack in a repository
# at a glance.
#
# Usage: bin/fm-stack-status.sh [--repo <owner/name>] [<pr-number>]
#   or:  bin/fm-stack-status.sh --help
#
# Discovers a repository's open pull requests and groups them into stacks: a
# chain of PRs whose base branch equals another open PR's head branch. For
# each stack it prints the chain from base to top, and for each member the
# title, checks summary, and merge state (clean, blocked, dirty, draft), with
# merge-queue membership when the forge reports it. Merged ancestors appear
# as a visible MERGED floor at the bottom of their stack, so the ground a
# merge attempt lands on is obvious from the listing alone. An orphan PR
# whose base matches no other open PR prints as its own stack.
#
# The default repository comes from the current checkout's origin remote, so
# running the script inside a project needs no flags; --repo names any
# owner/repository explicitly, for use from anywhere. Passing a PR number
# scopes the output to that PR's own stack.
#
# Read-only against the forge and the local checkout: every interaction is a
# list or read, and nothing merges, pushes, or mutates. Requires gh and jq on
# PATH. The GitHub-only reads split by payload weight so neither listing
# trips the GraphQL gateway's response cap: the PR inventory comes from
# paginated REST pulls, while per-PR merge details, checks, and queue
# membership come from batched GraphQL queries, 25 PRs at a time. A failed
# detail batch retries once, then the listing fails rather than rendering a
# half-informed stack. Detail reads are bounded to what the rendering shows:
# a repository with at most 100 open PRs gets details for every member, a
# larger one gets details only for members of multi-PR chains while orphan
# singletons render as bare titles, and scoping to a PR always fetches its
# whole stack's details.
set -u

usage() {
  cat <<'USAGE'
Usage: bin/fm-stack-status.sh [--repo <owner/name>] [<pr-number>]

Show every open PR stack in a repository: chains of PRs whose bases stack on
each other, each member's checks summary, merge state, and merge-queue
membership, with merged ancestors shown as a MERGED floor.

  --repo <owner/name>  the repository to read; default is the current
                       checkout's origin remote
  <pr-number>          scope the output to that PR's own stack
  -h, --help           this help

Read-only: lists and reads only, never merges, pushes, or mutates.
USAGE
  exit "${1:-0}"
}

fail() {
  printf 'fm-stack-status: %s\n' "$1" >&2
  exit 1
}

repo=
pr_number=
while [ $# -gt 0 ]; do
  case $1 in
    --repo)
      [ $# -ge 2 ] || usage 2
      repo=$2
      shift 2
      ;;
    --repo=*)
      repo=${1#--repo=}
      shift
      ;;
    -h | --help) usage 0 ;;
    -*)
      fail "unknown option: $1 (see --help)"
      ;;
    *)
      if [ -z "$pr_number" ] && [ -n "$1" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
        pr_number=$1
      else
        fail "unexpected argument: $1 (see --help)"
      fi
      shift
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || fail "gh is required on PATH"
command -v jq >/dev/null 2>&1 || fail "jq is required on PATH"

# shellcheck source=bin/fm-stack-status-lib.sh
. "$(dirname "$0")/fm-stack-status-lib.sh"

# Default the repository to the current checkout's origin.
if [ -z "$repo" ]; then
  origin_url=$(git remote get-url origin 2>/dev/null) ||
    fail "no --repo given and no origin remote in the current directory"
  repo=$(fm_stack_repo_of_url "$origin_url") ||
    fail "could not read an owner/name from the origin remote: $origin_url"
fi
case $repo in */*) : ;; *) fail "--repo expects owner/name: $repo" ;; esac
owner=${repo%%/*}
name=${repo#*/}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-stack-status.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
open_tsv=$tmp/open.tsv     # number, head, base, draft, title
detail_tsv=$tmp/detail.tsv # number, mergeable, mergeStateStatus, queue, rollup
summary_tsv=$tmp/summary.tsv # number, mergeable, mergeStateStatus, queue, checks summary
merged_tsv=$tmp/merged.tsv # number, head, base, title (most recent merge first)

# The default branch keeps sync PRs (head is main) from parenting every
# main-targeting PR into one degenerate stack; an unreadable default degrades
# to no exclusion.
default_branch=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null) || default_branch=

# --- open PR inventory (paginated REST, light fields) -------------------------

: > "$open_tsv"
page=1
while :; do
  page_json=$(gh api "repos/$repo/pulls?state=open&per_page=100&page=$page") ||
    fail "could not list open pull requests for $repo"
  page_count=$(printf '%s' "$page_json" | jq -r 'length' 2>/dev/null) || page_count=0
  [ "$page_count" -gt 0 ] || break
  printf '%s' "$page_json" | jq -r '.[]
    | select(.base != null and .head != null)
    | [.number, .head.ref, .base.ref, (.draft | tostring), .title] | @tsv' \
    >> "$open_tsv" || fail "could not parse the open pull request listing"
  [ "$page_count" -lt 100 ] && break
  page=$((page + 1))
  [ "$page" -le 20 ] || break # a hard cap keeps a pathological listing bounded
done
# A page shift during collection can duplicate a PR across pages; keep the
# first occurrence so grouping never sees one number twice.
sort -t "$(printf '\t')" -k1,1n -u -o "$open_tsv" "$open_tsv"

# --- merged-PR inventory for floor matching (recent closed pulls) -------------

# Collect two pages of recently closed pulls, keep the merged ones, and order
# them most recent merge first; the floor lookup takes the most recent PR on
# a reused head branch.
: > "$merged_tsv"
merged_all=$tmp/merged-all.tsv
: > "$merged_all"
for page in 1 2; do
  page_json=$(gh api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page") ||
    fail "could not list merged pull requests for $repo"
  printf '%s' "$page_json" | jq -r '.[]
    | select(.merged_at != null)
    | [.number, .head.ref, .base.ref, .title, .merged_at] | @tsv' \
    >> "$merged_all" || fail "could not parse the merged pull request listing"
done
sort -t "$(printf '\t')" -k5,5r "$merged_all" | head -n 100 | cut -f1-4 > "$merged_tsv"

# --- stack grouping (pure, over the light inventory) ---------------------------

fm_stack_group "$open_tsv" "$merged_tsv" "$default_branch" > "$tmp/groups.txt"

if [ ! -s "$open_tsv" ]; then
  printf 'no open pull requests in %s\n' "$repo"
  exit 0
fi

if [ -n "$pr_number" ]; then
  scoped=$(awk -v want="$pr_number" '
    /^stack / {
      if (keep) out = out block
      block = $0 "\n"
      keep = ($2 == want)
      if ($3 == "floor" && $4 != "-") {
        n = split($4, fl, " ")
        for (i = 1; i <= n; i++) if (fl[i] == want) keep = 1
      }
      next
    }
    /^member / {
      block = block $0 "\n"
      if ($2 == want) keep = 1
      next
    }
    END { if (keep) out = out block; printf "%s", out }' "$tmp/groups.txt")
  if [ -z "$scoped" ]; then
    fail "pull request $pr_number has no open stack in $repo"
  fi
  printf '%s\n' "$scoped" > "$tmp/groups.txt"
fi

# Detail reads are bounded to what the rendering shows: everything in a small
# repository, only multi-PR-chain members in a large one, or a scoped PR's
# whole stack.
open_count=$(wc -l < "$open_tsv" | tr -d ' ')
if [ -n "$pr_number" ] || [ "$open_count" -le 100 ]; then
  detail_numbers=$(awk '/^member /{print $2}' "$tmp/groups.txt")
else
  detail_numbers=$(awk '
    /^stack / { if (n > 1) print members; members = ""; n = 0; next }
    /^member / { members = members $2 "\n"; n++; next }
    END { if (n > 1) print members }' "$tmp/groups.txt")
fi

# --- per-PR merge details, checks, and queue membership (batched GraphQL) -----

: > "$detail_tsv"
batch_numbers=
batch_size=0
flush_batch() {
  [ -n "$batch_numbers" ] || return 0
  aliases=
  k=0
  for num in $batch_numbers; do
    aliases="$aliases a$k: pullRequest(number: $num) { number mergeable mergeStateStatus mergeQueueEntry { position } statusCheckRollup { contexts(last: 100) { nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } } } }"
    k=$((k + 1))
  done
  response=""
  for attempt in 1 2; do
    if response=$(gh api graphql \
      -f owner="$owner" -f name="$name" \
      -f query="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){$aliases}}"); then
      break
    elif [ "$attempt" -eq 2 ]; then
      fail "could not read merge details for $repo (GraphQL batch failed twice)"
    else
      sleep 2
    fi
  done
  printf '%s' "$response" | jq -r '.data.repository
    | to_entries[]
    | .value
    | select(.number != null)
    | [.number, .mergeable, .mergeStateStatus,
       ((.mergeQueueEntry // {}) | (.position // "" | tostring)),
       ((.statusCheckRollup.contexts.nodes // []) | tostring)] | @tsv' \
    >> "$detail_tsv" || fail "could not parse merge details for $repo"
  batch_numbers=
  batch_size=0
}
for num in $detail_numbers; do
  batch_numbers="$batch_numbers $num"
  batch_size=$((batch_size + 1))
  [ "$batch_size" -lt 25 ] || flush_batch
done
flush_batch

# Per-PR checks summaries in one jq pass over every detail record, sharing
# the lib's summary program.
: > "$summary_tsv"
jq -Rr "${FM_STACK_CHECKS_JQ_DEF}
  split(\"\t\") | select(length >= 5) |
  (.[4] | (if . == \"\" then [] else (fromjson? // []) end) | checks) as \$summary |
  [.[0], .[1], .[2], .[3], \$summary] | @tsv" "$detail_tsv" > "$summary_tsv" ||
  fail "could not summarize checks for $repo"

# --- rendering -----------------------------------------------------------------

# Join the group structure with the open, detail-summary, and merged records
# in one awk pass, so the render loop below stays free of per-member
# subprocess lookups on large repositories. Fields ride the unit separator
# so empty fields survive the render loop's read (whitespace separators
# would collapse consecutive delimiters).
awk -F' ' '
  BEGIN { sep = sprintf("%c", 31) }
  FILENAME == ARGV[1] { split($0, f, "\t"); o[f[1]] = f[4] sep f[5]; obase[f[1]] = f[3]; next }
  FILENAME == ARGV[2] { split($0, f, "\t"); d[f[1]] = f[2] sep f[3] sep f[4] sep f[5]; next }
  FILENAME == ARGV[3] { split($0, f, "\t"); m[f[1]] = f[4]; next }
  FILENAME == ARGV[4] {
    if ($1 == "stack") {
      stackn++
      if (stackn > 1) printf "\n"
      printf "stack%s%s%s%s\n", sep, stackn, sep, obase[$2]
      if ($4 != "-") {
        nf = split($4, fl, " ")
        for (i = 1; i <= nf; i++) printf "floor%s%s%s%s\n", sep, fl[i], sep, m[fl[i]]
      }
      next
    }
    if ($1 == "member") {
      split(o[$2], of, sep)
      split(d[$2], df, sep)
      printf "member%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", sep, $2, sep, of[1], sep, of[2], sep, df[1], sep, df[2], sep, df[3], sep, df[4]
    }
  }
' "$open_tsv" "$summary_tsv" "$merged_tsv" "$tmp/groups.txt" > "$tmp/render.tsv"

printf 'repo: %s\n' "$repo"
stack_count=0
while IFS=$'\x1f' read -r tag a b c d e f g; do
  case $tag in
    stack)
      stack_count=$((stack_count + 1))
      printf 'stack %s (base %s)\n' "$a" "$b"
      ;;
    floor)
      printf '  #%s  %s | MERGED\n' "$a" "$b"
      ;;
    member)
      # a=number b=draft c=title d=mergeable e=state f=queue g=summary;
      # empty detail fields mean no details were fetched for this member.
      if [ -z "$d" ] && [ -z "$e" ]; then
        printf '  #%s  %s | checks - | merge -\n' "$a" "$c"
        continue
      fi
      state_word=$(fm_stack_merge_state "$b" "$d" "$e")
      line="  #$a  $c | checks ${g:--} | merge $state_word"
      [ -n "$f" ] && line="$line | queue $f"
      printf '%s\n' "$line"
      ;;
  esac
done < "$tmp/render.tsv"

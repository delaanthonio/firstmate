#!/usr/bin/env bash
# Shared pure helpers for bin/fm-stack-status.sh: check-rollup summaries,
# merge-state classification, origin-to-repo parsing, and stack-chain grouping
# over tab-separated line records. The script owns every forge read and the
# rendering; everything here is side-effect free so tests can drive it with
# fixture data and no network. Records are one pull request per line with
# tab-separated fields; open records carry
#   number, head, base, draft, title
# and merged records carry
#   number, head, base, title
# ordered most recently merged first. Everything runs on stock macOS bash 3.2
# plus standard awk: no associative arrays, and grouping is one awk pass so a
# large repository never pays quadratic bash scans.

# The checks-summary jq program: one PR's statusCheckRollup (a JSON array of
# CheckRun or StatusContext objects) reduced to "<ok>/<total> green" with
# failed and pending counts appended when nonzero, or "none" for an absent or
# empty rollup. Defined as a function so the single-PR helper and the
# script's batched summary pass share one implementation.
# shellcheck disable=SC2016  # the jq program is deliberately single-quoted
FM_STACK_CHECKS_JQ_DEF='
def checks:
  if (type != "array") or (length == 0) then
    "none"
  else
    [ .[] |
      if .__typename == "CheckRun" then
        if .status != "COMPLETED" then "pending"
        elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "green"
        elif .conclusion == null or .conclusion == "" then "pending"
        else "failed" end
      else
        {PENDING: "pending", EXPECTED: "pending", SUCCESS: "green",
         FAILURE: "failed", ERROR: "failed"}[.state] // "pending"
      end
    ] as $v
    | ($v | map(select(. == "green")) | length) as $ok
    | ($v | map(select(. == "failed")) | length) as $bad
    | ($v | map(select(. == "pending")) | length) as $wait
    | "\($ok)/\($v | length) green" +
      (if $bad > 0 then " \($bad) failed" else "" end) +
      (if $wait > 0 then " \($wait) pending" else "" end)
  end;
'

# fm_stack_checks_summary <rollup-json>
# Summarize one pull request's statusCheckRollup; see FM_STACK_CHECKS_JQ_DEF.
fm_stack_checks_summary() {
  local rollup=${1:-}
  if [ -z "$rollup" ]; then
    printf 'none\n'
    return
  fi
  printf '%s' "$rollup" | jq -r "${FM_STACK_CHECKS_JQ_DEF} checks"
}

# fm_stack_merge_state <isDraft> <mergeable> <mergeStateStatus>
# Reduce the forge's per-PR merge fields to one word: draft, dirty (conflict
# markers or a conflicting mergeable read), blocked (checks or review rules),
# clean, or unknown when the forge has not finished computing a verdict.
fm_stack_merge_state() {
  local draft=${1:-} mergeable=${2:-} state=${3:-}
  if [ "$draft" = true ]; then
    printf 'draft\n'
    return
  fi
  case $mergeable in
    CONFLICTING) printf 'dirty\n' ; return ;;
  esac
  case $state in
    DIRTY) printf 'dirty\n' ;;
    BLOCKED | UNSTABLE | BEHIND) printf 'blocked\n' ;;
    CLEAN | HAS_HOOKS) printf 'clean\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# fm_stack_repo_of_url <git-url>
# Extract <owner>/<name> from a git remote URL - https, ssh (scp-like or
# ported), or a plain local path - by taking the last two path segments, or
# fail when the URL carries no such two-segment path.
fm_stack_repo_of_url() {
  local url=$1 path owner name
  case $url in
    *://*)
      path=${url#*://} # drop the scheme
      path=${path#*/} # drop the authority: host, optional user@, and port
      ;;
    *)
      path=$url
      case $path in
        *@*) path=${path#*:} ;; # scp-like user@host: drops its host part
      esac
      ;;
  esac
  case $path in
    */*) : ;;
    *) return 1 ;;
  esac
  name=${path##*/}
  name=${name%.git}
  owner=${path%/*}
  owner=${owner##*/}
  owner=${owner##*:}
  owner=${owner##*@}
  case $name in '' | '.' | '..') return 1 ;; esac
  case $owner in '' | '.' | '..') return 1 ;; esac
  case $owner in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case $name in *[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/%s\n' "$owner" "$name"
}

# fm_stack_group <open-records-file> <merged-records-file> [default-branch]
# Group open PRs into stacks: a chain whose members' base branches equal
# another open member's head branch. An open PR whose head IS the default
# branch - a sync or back-merge PR - never parents other PRs, and a merged
# PR on the default branch never floors one, so main-targeting PRs stay
# their own stacks instead of collapsing into one degenerate chain. Prints
# one "stack <root-number> floor <oldest..newest | ->" line per stack
# followed by one "member <number> <depth>" line per open member, stacks by
# ascending root number and members base to top. The floor lists merged
# ancestors matched by branch name (a merged PR's head being the base of the
# next one), oldest first, so the rendering can show the merged ground each
# stack builds on; "-" names a stack with no merged ancestor. An orphan PR
# is a one-member stack.
fm_stack_group() {
  local open_file=$1 merged_file=$2 default_branch=${3:-}

  # One awk pass over both record files: the head-branch index, parent walk,
  # and floor chain are hash-table work that bash's parallel arrays would
  # turn into quadratic scans on a large repository.
  awk -F'\t' -v default_branch="$default_branch" '
    FILENAME == ARGV[1] {
      if ($1 != "" && $2 != "" && $2 != default_branch && !($2 in m_head)) m_head[$2] = $1
      m_base[$1] = $3
      next
    }
    FILENAME == ARGV[2] {
      if ($1 == "") next
      n++
      num[n] = $1
      if (!($2 in head_owner) && $2 != default_branch) head_owner[$2] = n
      base[$1] = $3
      next
    }
    END {
      # Parent index: the first (lowest-numbered) open PR whose head branch
      # equals this base branch, or empty for a stack bottom. A PR whose
      # head is the default branch never parents: base==main hanging on a
      # sync PR whose head is main is not a stack.
      for (i = 1; i <= n; i++) {
        parent[i] = (base[num[i]] in head_owner) ? head_owner[base[num[i]]] : ""
      }
      # Root and depth: walk the parent chain down; a walk longer than the
      # PR count can only be a base/head cycle, treated as its own stack
      # bottom.
      for (i = 1; i <= n; i++) {
        cur = i
        steps = 0
        while (parent[cur] != "" && steps <= n) {
          cur = parent[cur]
          steps++
        }
        if (steps > n) cur = i
        root[i] = cur
        depth[i] = steps
      }
      # Emit stacks by ascending root number (open records arrive sorted by
      # PR number), members base to top: depth ascending, then number.
      for (i = 1; i <= n; i++) {
        if (root[i] != i) continue
        rnum = num[i]
        fl = "-"
        chain = ""
        b = base[rnum]
        walk = 0
        while (b in m_head && walk <= n) {
          chain = chain " " m_head[b]
          b = m_base[m_head[b]]
          walk++
        }
        if (chain != "") {
          nf = split(chain, fa, " ")
          fl = fa[nf]
          for (k = nf - 1; k >= 1; k--) fl = fl " " fa[k]
        }
        printf "stack %s floor %s\n", rnum, fl
        for (d = 0; d <= n; d++) {
          found = 0
          for (j = 1; j <= n; j++) {
            if (root[j] == i && depth[j] == d) {
              printf "member %s %d\n", num[j], depth[j]
              found = 1
            }
          }
          if (!found) break # no members left at any deeper depth
        }
      }
    }
  ' "$merged_file" "$open_file"
}

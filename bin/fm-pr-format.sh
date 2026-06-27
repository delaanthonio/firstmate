#!/usr/bin/env bash
# Reformat a PR's description for readability, once, after no-mistakes opens it.
#
# Usage: fm-pr-format.sh <pr-url>
#
# no-mistakes auto-generates a serviceable but dense PR body (intent summary plus
# machine notes). This helper hands that body to an agent to rewrite into a clean,
# scannable description (sections, bullets) WITHOUT losing any content, then
# writes it back with `gh pr edit`. It is a readability pass over metadata, not a
# code change, so firstmate runs it directly rather than spawning a worktree
# crewmate (see AGENTS.md PR ready).
#
# Idempotent and safe:
#   - One reformat per PR: the rewritten body ends with a hidden marker comment;
#     a body that already carries it is left untouched.
#   - Never destroys real content: if the agent returns nothing, fails, or
#     returns a body far shorter than the original (suspected truncation), the
#     helper aborts and leaves the PR body exactly as it was.
#
# Two injection points keep it testable and portable (both default to the tools
# firstmate already uses):
#   FM_PR_FORMAT_AGENT  the rewrite agent; reads the prompt on stdin, writes the
#                       new markdown body to stdout. Default: `claude -p`.
#   FM_PR_FORMAT_GH     the GitHub CLI. Default: `gh`. Raw `gh` is used (not
#                       gh-axi) for the same reason as fm-pr-check.sh's poll: the
#                       PR URL selects the exact repo+PR, which matters when
#                       origin is a fork and gh-axi (number-only) would resolve
#                       the wrong repo.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
"$FM_ROOT/bin/fm-guard.sh" || true

URL=${1:?usage: fm-pr-format.sh <pr-url>}
case "$URL" in
  https://github.com/*/*/pull/*) ;;
  *) echo "error: not a GitHub PR URL: $URL" >&2; exit 1 ;;
esac

GH=${FM_PR_FORMAT_GH:-gh}
AGENT=${FM_PR_FORMAT_AGENT:-claude -p}
MARKER='<!-- fm-pr-format -->'
# Below this fraction of the original length the rewrite is treated as content loss.
MIN_RATIO_PCT=${FM_PR_FORMAT_MIN_RATIO_PCT:-40}

title=$($GH pr view "$URL" --json title -q .title 2>/dev/null || true)
body=$($GH pr view "$URL" --json body -q .body 2>/dev/null || true)

if [ -z "${body//[[:space:]]/}" ]; then
  echo "skip: PR $URL has an empty body; nothing to reformat"
  exit 0
fi
case "$body" in
  *"$MARKER"*) echo "skip: PR $URL already reformatted (marker present)"; exit 0 ;;
esac

prompt=$(cat <<EOF
You are reformatting a GitHub pull request description for readability.
Rewrite the description below into clean, well-structured, scannable Markdown:
- Use clear section headings and bullet lists where they help.
- PRESERVE every fact, link, URL, code reference, checklist item, risk note, and footer. Do not invent, remove, or contradict any content.
- Improve structure and wording only; keep it faithful and concise.
- Output ONLY the rewritten Markdown body: no preamble, no commentary, no surrounding code fence.

PR title: $title

--- current description ---
$body
--- end description ---
EOF
)

new=$(printf '%s' "$prompt" | $AGENT 2>/dev/null) || {
  echo "error: rewrite agent failed; leaving PR $URL body unchanged" >&2
  exit 1
}

# Normalize: drop leading/trailing blank lines and a stray wrapping code fence
# if the agent ignored the "no fence" rule. awk keeps this portable (BSD/GNU).
new=$(printf '%s\n' "$new" | awk '
  { buf[NR] = $0 }
  END {
    s = 1; e = NR
    while (s <= e && buf[s] ~ /^[[:space:]]*$/) s++
    if (s <= e && buf[s] ~ /^```/) {
      s++
      while (e >= s && buf[e] ~ /^[[:space:]]*$/) e--
      if (e >= s && buf[e] ~ /^```[[:space:]]*$/) e--
    }
    while (e >= s && buf[e] ~ /^[[:space:]]*$/) e--
    for (i = s; i <= e; i++) print buf[i]
  }')

if [ -z "${new//[[:space:]]/}" ]; then
  echo "error: rewrite agent returned an empty body; leaving PR $URL unchanged" >&2
  exit 1
fi

# Content-loss guard: a reformat should be roughly the same size, never a fraction.
orig_len=${#body}
new_len=${#new}
if [ "$orig_len" -gt 0 ]; then
  min_len=$(( orig_len * MIN_RATIO_PCT / 100 ))
  if [ "$new_len" -lt "$min_len" ]; then
    echo "error: reformatted body ($new_len chars) is under ${MIN_RATIO_PCT}% of the original ($orig_len chars); suspected content loss, leaving PR $URL unchanged" >&2
    exit 1
  fi
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pr-format.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n\n%s\n' "$new" "$MARKER" > "$tmp"

if ! $GH pr edit "$URL" --body-file "$tmp" >/dev/null 2>&1; then
  echo "error: failed to update PR $URL body; it is unchanged" >&2
  exit 1
fi

echo "reformatted: PR $URL body rewritten for readability (one-time)"

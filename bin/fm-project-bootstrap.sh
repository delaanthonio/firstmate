#!/usr/bin/env bash
# Bootstrap dependencies in an isolated worker worktree before agent launch.
# Usage: fm-project-bootstrap.sh <project-dir> <worktree> [--fresh]
# Configuration schema: docs/configuration.md "Project dependency bootstrap".
# Runs detected root-level dependency managers, or the configured Bash command,
# from the worktree, streaming diagnostics and refusing on any failure.
# --fresh always bootstraps; otherwise an unchanged successful receipt skips it.
# Receipts and the serialization lock live in the worktree's own git directory,
# never its tracked files or the repository's shared common directory. A receipt
# binds the command, worktree path, and dependency marker contents (including
# absent markers). Only success publishes it. Package managers own their caches
# and dependency locks; this lock prevents overlapping bootstraps of one copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ]; then
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
PROJECT=${1:?usage: fm-project-bootstrap.sh <project-dir> <worktree> [--fresh]}
WORKTREE=${2:?usage: fm-project-bootstrap.sh <project-dir> <worktree> [--fresh]}
FRESH=${3:-}
if [ "$#" -gt 3 ] || { [ -n "$FRESH" ] && [ "$FRESH" != --fresh ]; }; then
  echo 'error: expected only project, worktree, and optional --fresh' >&2
  exit 1
fi
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PROJECT=$(cd "$PROJECT" && pwd -L)
WORKTREE=$(cd "$WORKTREE" && pwd -P)
NAME=${PROJECT##*/}
DECLARATION="$CONFIG/project-bootstrap.json"
COMMAND=
MARKERS=(uv.lock pyproject.toml uv.toml .python-version mise.toml .mise.toml mise.lock .mise.lock
  .tool-versions package-lock.json package.json .npmrc Cargo.lock Cargo.toml rust-toolchain.toml
  rust-toolchain .cargo/config.toml Gemfile.lock Gemfile .ruby-version .bundle/config)
if [ -e "$DECLARATION" ] || [ -L "$DECLARATION" ]; then
  if ! jq -e '
    type == "object" and all(.[];
      type == "object" and
      (keys - ["command", "markers"] | length == 0) and
      (.command | type == "string" and test("[^\\s]") and (contains("\u0000") | not)) and
      ((has("markers") | not) or (.markers | type == "array" and all(.[];
        type == "string" and length > 0 and
        (test("[\\x00-\\x1f]") | not) and
        (startswith("/") | not) and
        (split("/") | all(. != ".." and . != "." and . != "")))))
    )' "$DECLARATION" >/dev/null; then
    echo "error: invalid dependency bootstrap configuration: $DECLARATION" >&2
    exit 1
  fi
  COMMAND=$(jq -r --arg name "$NAME" '.[$name].command // empty' "$DECLARATION")
  while IFS= read -r marker; do
    [ -z "$marker" ] || MARKERS+=("$marker")
  done < <(jq -r --arg name "$NAME" '.[$name].markers[]?' "$DECLARATION")
fi
if [ -z "$COMMAND" ]; then
  # Install toolchains before invoking dependency managers they may provide.
  if [ -f "$WORKTREE/mise.toml" ] || [ -f "$WORKTREE/.mise.toml" ]; then
    COMMAND+=$'mise install\n'
  fi
  [ ! -f "$WORKTREE/uv.lock" ] || COMMAND+=$'uv sync\n'
  [ ! -f "$WORKTREE/package-lock.json" ] || COMMAND+=$'npm ci\n'
  [ ! -f "$WORKTREE/Cargo.lock" ] || COMMAND+=$'cargo fetch\n'
  [ ! -f "$WORKTREE/Gemfile.lock" ] || COMMAND+=$'bundle install\n'
fi
[ -n "$COMMAND" ] || exit 0

GIT_DIR=$(git -C "$WORKTREE" rev-parse --absolute-git-dir)
RECEIPT="$GIT_DIR/fm-project-bootstrap.receipt"
LOCK="$GIT_DIR/fm-project-bootstrap.lock"
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK"
  rm -f -- "$RECEIPT.${BASHPID:-$$}.tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! fm_lock_acquire_wait_max "$LOCK" 600; then
  echo "error: timed out waiting for dependency bootstrap lock for $WORKTREE" >&2
  exit 1
fi
LOCK_HELD=1

fingerprint() {
  local marker hash
  printf 'v1\n%s\n%s\n' "$WORKTREE" "$COMMAND"
  for marker in "${MARKERS[@]}"; do
    if [ -e "$WORKTREE/$marker" ] || [ -L "$WORKTREE/$marker" ]; then
      hash=$(git -C "$WORKTREE" hash-object --no-filters -- "$marker") || return 1
    else
      hash=absent
    fi
    printf '%s %s\n' "$hash" "$marker"
  done
}
FINGERPRINT=$(fingerprint | git -C "$WORKTREE" hash-object --stdin)
if [ "$FRESH" != --fresh ] && [ -f "$RECEIPT" ] && [ "$(cat "$RECEIPT")" = "$FINGERPRINT" ]; then
  echo "bootstrap: dependencies unchanged in $WORKTREE" >&2
  exit 0
fi
# Invalidate earlier success before running: a failing sync may have partially
# replaced dependencies, even when its inputs match an older receipt.
rm -f -- "$RECEIPT"
printf 'bootstrap: %s in %s\n' "$COMMAND" "$WORKTREE" >&2
if (cd "$WORKTREE" && bash -e -o pipefail -c "$COMMAND"); then
  printf '%s\n' "$FINGERPRINT" >"$RECEIPT.${BASHPID:-$$}.tmp"
  mv -f -- "$RECEIPT.${BASHPID:-$$}.tmp" "$RECEIPT"
else
  result=$?
  printf 'error: dependency bootstrap failed (exit %s) in %s; worker was not launched\n' "$result" "$WORKTREE" >&2
  exit "$result"
fi

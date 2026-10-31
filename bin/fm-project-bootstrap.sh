#!/usr/bin/env bash
# Bootstrap dependencies in an isolated worker worktree before agent launch.
# Usage: fm-project-bootstrap.sh <project-dir> <worktree>
# Configuration schema: docs/configuration.md "Project dependency bootstrap".
# Runs detected root-level dependency managers, or the configured Bash command,
# from the worktree, streaming diagnostics and refusing on any failure.
# An unchanged successful receipt skips detected uv/npm commands only while
# every expected local dependency output directory exists.
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
PROJECT=${1:?usage: fm-project-bootstrap.sh <project-dir> <worktree>}
WORKTREE=${2:?usage: fm-project-bootstrap.sh <project-dir> <worktree>}
if [ "$#" -ne 2 ]; then
  echo 'error: expected only project and worktree' >&2
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
CACHEABLE=1
OUTPUTS=()
MARKERS=(uv.lock pyproject.toml setup.py setup.cfg uv.toml .python-version mise.toml .mise.toml mise.lock .mise.lock
  .tool-versions package-lock.json package.json .npmrc Cargo.lock Cargo.toml rust-toolchain.toml
  rust-toolchain .cargo/config.toml Gemfile.lock Gemfile .ruby-version .bundle/config)
if [ -e "$DECLARATION" ] || [ -L "$DECLARATION" ]; then
  if ! jq -e '
    type == "object" and all(.[];
      type == "object" and
      (keys - ["command"] | length == 0) and
      (.command | type == "string" and test("[^\\s]") and (contains("\u0000") | not))
    )' "$DECLARATION" >/dev/null; then
    echo "error: invalid dependency bootstrap configuration: $DECLARATION" >&2
    exit 1
  fi
  COMMAND=$(jq -r --arg name "$NAME" '.[$name].command // empty' "$DECLARATION")
fi
check_dependency_layouts() {
  local directory=$1 depth=$2 manifest required path
  for manifest in uv.lock package-lock.json Cargo.lock Gemfile.lock \
    pyproject.toml package.json Cargo.toml Gemfile pnpm-lock.yaml yarn.lock \
    bun.lock bun.lockb npm-shrinkwrap.json requirements.txt requirements-dev.txt \
    Pipfile Pipfile.lock poetry.lock setup.py setup.cfg go.mod go.sum composer.json composer.lock; do
    [ -f "$directory/$manifest" ] || continue
    if [ "$directory" != "$WORKTREE" ]; then
      echo "error: nested dependency layout ${directory#"$WORKTREE"/}/$manifest requires a bootstrap command; configure command for '$NAME' in $DECLARATION" >&2
      return 1
    fi
    case "$manifest" in
      uv.lock | package-lock.json | Cargo.lock | Gemfile.lock) continue ;;
      pyproject.toml | setup.py | setup.cfg) required=uv.lock ;;
      package.json) required=package-lock.json ;;
      Cargo.toml) required=Cargo.lock ;;
      Gemfile) required=Gemfile.lock ;;
      *) required= ;;
    esac
    if [ -z "$required" ] || [ ! -f "$WORKTREE/$required" ]; then
      echo "error: no dependency bootstrap command for $manifest${required:+ (requires $required)} in $WORKTREE; configure command for '$NAME' in $DECLARATION" >&2
      return 1
    fi
  done
  [ "$depth" -lt 2 ] || return 0
  for path in "$directory"/*; do
    [ -d "$path" ] && [ ! -L "$path" ] || continue
    case "${path##*/}" in
      .* | vendor | node_modules) continue ;;
    esac
    check_dependency_layouts "$path" "$((depth + 1))" || return 1
  done
}
if [ -n "$COMMAND" ]; then
  CACHEABLE=0
else
  check_dependency_layouts "$WORKTREE" 0
  if [ -f "$WORKTREE/uv.lock" ]; then
    COMMAND+=$'uv sync\n'
    OUTPUTS+=(.venv)
  fi
  if [ -f "$WORKTREE/package-lock.json" ]; then
    COMMAND+=$'npm ci\n'
    OUTPUTS+=(node_modules)
  fi
  if [ -f "$WORKTREE/Cargo.lock" ]; then
    COMMAND+=$'cargo fetch\n'
    CACHEABLE=0
  fi
  if [ -f "$WORKTREE/Gemfile.lock" ]; then
    COMMAND+=$'bundle install\n'
    CACHEABLE=0
  fi
  if [ -f "$WORKTREE/mise.toml" ] || [ -f "$WORKTREE/.mise.toml" ]; then
    if [ -n "$COMMAND" ]; then
      printf -v COMMAND 'mise install\nmise exec -- bash -e -o pipefail -c %q' "$COMMAND"
    else
      COMMAND='mise install'
      CACHEABLE=0
    fi
  fi
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
  printf 'v2\n%s\n%s\n' "$WORKTREE" "$COMMAND"
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
for output in ${OUTPUTS[@]+"${OUTPUTS[@]}"}; do
  [ -d "$WORKTREE/$output" ] || CACHEABLE=0
done
if [ "$CACHEABLE" = 1 ] && [ -f "$RECEIPT" ] && [ "$(cat "$RECEIPT")" = "$FINGERPRINT" ]; then
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

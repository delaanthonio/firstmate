#!/usr/bin/env bash
# Read-only fleet validation attention monitor.
#
# Usage: fm-validation-monitor.sh [check|arm|disarm|--help]
# arm registers validation-monitor.check.sh with the existing standing-check
# runner; it never starts another watcher. Bootstrap arms it when the local
# config/validation-monitor.json exists. docs/configuration.md owns its schema.
# check prints one plain one-line reason containing newly observed conditions,
# with exact run-targeted abort commands for an operator, and otherwise nothing.
# Only this home's monitor observations and registration are written; no run,
# project, worker, daemon, or forge is ever changed.
#
# Python 3 supplies bounded subprocess reads, TOON table decoding, optional
# read-only SQLite inventory expansion, and private atomic observations.
# Internal --read/--facts/--bind/--worker/--database operations are the bridge
# to the existing run-attribution and backend primitives, not operator actions.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

case "${1:-check}" in
--read)
  repo=$2
  shift 2
  case "$*" in
  axi | 'runs --limit 1000' | axi\ status\ --run\ *) fm_nm_run_checked "$repo" 5 "$@" ;;
  *) exit 2 ;;
  esac
  ;;
--database) fm_nm_state_db "$2" ;;
--facts)
  detail=$(</dev/stdin)
  active=0 parked=0
  fm_nm_run_is_active "$detail" && active=1
  fm_nm_run_is_parked "$detail" && parked=1
  printf '%s %s\n' "$active" "$parked"
  ;;
--bind)
  detail=$(</dev/stdin)
  head=$(fm_nm_strip_quotes "$(fm_nm_field "$detail" head_sha)")
  [ -n "$head" ] || head=$(fm_nm_strip_quotes "$(fm_nm_field "$detail" head)")
  if fm_nm_run_is_executing "$detail" ||
    fm_nm_run_is_pipeline_owned_active "$detail" ||
    fm_nm_head_matches_worktree "$2" "$head"; then
    printf 'bound\n'
  fi
  ;;
--worker)
  # Shared classifiers own every supported harness/backend verdict. Unknown
  # is never converted into idle or death by this monitor.
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  meta=$2
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || {
    printf 'unknown\n'
    exit 0
  }
  target=$(fm_backend_target_of_meta "$meta") || target=''
  [ -n "$target" ] || {
    printf 'gone\n'
    exit 0
  }
  backend=$(fm_backend_of_meta "$meta")
  case "$(fm_backend_agent_state "$backend" "$target")" in
  dead | missing)
    printf 'gone\n'
    exit 0
    ;;
  esac
  verdict=$(fm_busy_classify_meta "$meta" "$(basename "$meta" .meta)" "$(dirname "$meta")")
  case "$verdict" in
  busy\ *) printf 'busy\n' ;;
  idle\ *) printf 'idle\n' ;;
  dead\ *) printf 'gone\n' ;;
  *) printf 'unknown\n' ;;
  esac
  ;;
-h | --help)
  printf '%s\n' 'Usage: fm-validation-monitor.sh [check|arm|disarm|--help]' \
    'Read-only validation attention checks; arm uses the existing watcher.' \
    'Configuration and thresholds: docs/configuration.md, Validation monitor.'
  ;;
check | arm | disarm)
  command -v python3 >/dev/null 2>&1 || exit 0
  exec python3 "$SCRIPT_DIR/fm-validation-monitor.py" "${1:-check}"
  ;;
*)
  printf 'error: unknown validation monitor action\n' >&2
  exit 2
  ;;
esac

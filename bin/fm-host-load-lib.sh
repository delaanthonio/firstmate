#!/usr/bin/env bash
# fm-host-load-lib.sh - the machine's one-minute load-average ceiling for
# launching a fresh worker, and whether a fresh spawn still fits under it.
#
# A fleet of concurrent workers shares one machine, and its load is created by
# all of them together: several projects' test suites running at once can push
# the host so hard that timing-sensitive tests fail flakily and every
# validation on it stalls. Per-project capacity (bin/fm-project-capacity-lib.sh)
# bounds the workers one project admits, but no per-project declaration can see
# the machine as a whole. The captain declares a machine-wide one-minute
# load-average ceiling, and bin/fm-spawn.sh defers a fresh ship or scout beyond
# it instead of launching another worker into an overloaded host. A deferred
# task keeps its queued backlog item and is dispatched again once the machine
# cools, or launched under the captain's explicit --allow-over-load order.
# Without a declaration nothing changes: no load is read and no launch is ever
# deferred for the machine's load.
#
# This file is the single owner of the ceiling declaration format, of the load
# source, and of the over-ceiling verdict. docs/configuration.md "Spawn load
# ceiling" is the operator reference, and bin/fm-spawn.sh owns where the check
# runs.
#
# Declaration: config/spawn-load-ceiling in the local root Firstmate home (the
# home bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on
# this machine reads the same limit for the same machine. The file holds one
# positive number: the highest one-minute load average at which a fresh launch
# is still admitted. Blank lines and `#` comment lines are ignored, so the
# captain can record why the number was chosen beside it. Any other shape - a
# second number, a negative or zero ceiling, a token that is not a number, an
# unreadable file - makes the declaration unreadable, and bin/fm-spawn.sh then
# refuses every fresh ship or scout spawn from this machine's homes rather than
# guessing the intended limit. Absent a declaration the guard is off.
#
# Load source: /proc/loadavg's first field where that file is readable, and
# `sysctl -n vm.loadavg` elsewhere. When a ceiling is configured but no source
# can be read, the spawn is refused rather than admitted, since skipping the
# check would silently ignore the limit the captain set.
#
# Verdict: a spawn is deferred when the observed load is strictly above the
# ceiling; a spawn at exactly the ceiling is admitted. The comparison is
# decimal, so an integral ceiling of 8 admits a load of 7.5 and defers 8.5.
#
# Test seam: FM_TEST_HOST_LOAD_1M names a file holding the one-minute load,
# which fm_host_load_one_minute reads in place of the real sources - and whose
# unreadability stands in for an unreadable source - only when FM_TEST_SEAM=1;
# tests/lib.sh arms the marker for isolated suites, so a leaked value alone
# stays inert outside a suite.
#
# Requires bin/fm-wake-lib.sh (root home) to be sourced first. No side effects
# on source.

# Exit status of a spawn deferred because the machine is above its load
# ceiling: the same sysexits "temporary failure" code as a project-capacity
# deferral, so a caller can tell a deferral that leaves the task queued from an
# ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SPAWN_LOAD_DEFER_EXIT=75

# The config directory holding this machine's ceiling: the spawning home's own
# <config-dir> when that home is the local root (so an override of it applies),
# otherwise the root home's config/. Mirrors
# fm_project_capacity_config_dir in bin/fm-project-capacity-lib.sh.
fm_host_load_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Whether <value> is a nonnegative decimal number: digits with at most one dot,
# and at least one digit on each side of any dot, so "8", "8.5", and "0.5" are
# valid while "", ".5", "8.", "8.5.1", and "eight" are not.
fm_host_load_number_valid() {  # <value>
  case $1 in
    '' | *[!0-9.]*) return 1 ;;
  esac
  case ${1%%.*} in
    '' | *[!0-9]*) return 1 ;;
  esac
  case $1 in
    *.*)
      case ${1#*.} in
        '' | *[!0-9]* | *.*) return 1 ;;
      esac
      ;;
  esac
  return 0
}

# Read the declared ceiling. Sets FM_HOST_LOAD_CEILING_FILE to the declaration
# path, FM_HOST_LOAD_CEILING to the ceiling, or to empty when no file declares
# one (the guard is off). Returns 1 with FM_HOST_LOAD_CEILING_ERROR when the
# file exists but is unreadable or malformed.
fm_host_load_ceiling_lookup() {  # <config-dir>
  local line raw=''
  FM_HOST_LOAD_CEILING_FILE="$1/spawn-load-ceiling"
  FM_HOST_LOAD_CEILING=
  FM_HOST_LOAD_CEILING_ERROR=
  if [ ! -e "$FM_HOST_LOAD_CEILING_FILE" ] && [ ! -L "$FM_HOST_LOAD_CEILING_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_HOST_LOAD_CEILING_FILE" ] || [ ! -r "$FM_HOST_LOAD_CEILING_FILE" ]; then
    FM_HOST_LOAD_CEILING_ERROR="$FM_HOST_LOAD_CEILING_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    if [ -n "$raw" ]; then
      FM_HOST_LOAD_CEILING_ERROR="$FM_HOST_LOAD_CEILING_FILE holds a second number, $line"
      return 1
    fi
    raw=$line
  done < "$FM_HOST_LOAD_CEILING_FILE"
  if [ -z "$raw" ]; then
    FM_HOST_LOAD_CEILING_ERROR="$FM_HOST_LOAD_CEILING_FILE holds no load ceiling"
    return 1
  fi
  if ! fm_host_load_number_valid "$raw"; then
    FM_HOST_LOAD_CEILING_ERROR="$FM_HOST_LOAD_CEILING_FILE holds $raw, which is not a positive number"
    return 1
  fi
  case $(awk -v c="$raw" 'BEGIN { print (c + 0 > 0) ? 1 : 0 }') in
    1) ;;
    *)
      FM_HOST_LOAD_CEILING_ERROR="$FM_HOST_LOAD_CEILING_FILE holds $raw, which is not a positive number"
      return 1
      ;;
  esac
  FM_HOST_LOAD_CEILING=$raw
  return 0
}

# Read the machine's one-minute load average. Sets FM_HOST_LOAD_1M to the
# observed load, or returns 1 with FM_HOST_LOAD_ERROR when no source can be
# read. The test seam above is the first source, so a suite never depends on
# the machine it runs on being quiet or even having a load source.
fm_host_load_one_minute() {
  local raw=''
  FM_HOST_LOAD_1M=
  FM_HOST_LOAD_ERROR=
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_HOST_LOAD_1M:-}" ]; then
    if [ -f "$FM_TEST_HOST_LOAD_1M" ] && [ -r "$FM_TEST_HOST_LOAD_1M" ]; then
      raw=$(head -n 1 "$FM_TEST_HOST_LOAD_1M" 2>/dev/null) || raw=
      if fm_host_load_number_valid "$raw"; then
        FM_HOST_LOAD_1M=$raw
        return 0
      fi
    fi
    FM_HOST_LOAD_ERROR="the test load source $FM_TEST_HOST_LOAD_1M is not a readable file holding a number"
    return 1
  fi
  if [ -r /proc/loadavg ]; then
    raw=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || raw=
  elif command -v sysctl >/dev/null 2>&1; then
    raw=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}') || raw=
  else
    raw=
  fi
  if ! fm_host_load_number_valid "$raw"; then
    FM_HOST_LOAD_ERROR="no readable one-minute load source (/proc/loadavg or sysctl vm.loadavg)"
    return 1
  fi
  FM_HOST_LOAD_1M=$raw
  return 0
}

# The over-ceiling verdict: returns 0 when <load> is strictly above <ceiling>,
# and 1 when it is at or below it. Both operands are validated decimals by the
# callers, so the comparison itself is decimal arithmetic, not a string order.
fm_host_load_over() {  # <load> <ceiling>
  awk -v l="$1" -v c="$2" 'BEGIN { exit (l + 0 > c + 0) ? 0 : 1 }'
}

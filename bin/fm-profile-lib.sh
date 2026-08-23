#!/usr/bin/env bash

# shellcheck disable=SC2034 # Sourced callers use this diagnostic label.
FM_PROFILE_EFFORT_VALUES="low, medium, high, xhigh, max, dynamic"

fm_profile_effort_valid() {
  case "$1" in
    low|medium|high|xhigh|max|dynamic) return 0 ;;
  esac
  return 1
}

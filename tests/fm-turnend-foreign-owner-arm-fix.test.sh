#!/usr/bin/env bash
# Regression for the live foreign session-lock owner and non-owner Stop loop.
# The executable reproduction runs the real auto-arm and turn-end guard paths.
set -eu

# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"
exec python3 "$(dirname "${BASH_SOURCE[0]}")/fm-turnend-foreign-owner-repro.py" "$@"

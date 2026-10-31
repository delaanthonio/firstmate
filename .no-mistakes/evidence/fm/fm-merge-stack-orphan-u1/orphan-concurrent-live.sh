#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.phase-test/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/user" "$LAB/gh" "$LAB/tmp"
export FM_HOME="$LAB" HOME="$LAB/user" GH_CONFIG_DIR="$LAB/gh" TMPDIR="$LAB/tmp"
export PATH=/Users/dela/.local/share/mise/installs/node/24.20.0/bin:$PATH
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"

for round in 1 2 3; do
  URL=https://github.com/fm-live-validation/disposable/pull/$((round+20))
  printf '\nSCENARIO two concurrent registrations compete for the same unowned PR: round %s\n' "$round"
  bin/fm-pr-check.sh "owner-a-$round" "$URL" --orphan > "$LAB/a.out" 2>&1 &
  a=$!
  bin/fm-pr-check.sh "owner-b-$round" "$URL" --orphan > "$LAB/b.out" 2>&1 &
  b=$!
  ra=0; rb=0
  wait "$a" || ra=$?
  wait "$b" || rb=$?
  printf 'Recorder A: exit=%s\n' "$ra"; cat "$LAB/a.out"
  printf 'Recorder B: exit=%s\n' "$rb"; cat "$LAB/b.out"
  [ "$ra:$rb" = 0:1 ] || [ "$ra:$rb" = 1:0 ]
  count=0
  for path in "$LAB/state/owner-a-$round.meta" "$LAB/state/owner-b-$round.meta"; do
    [ -f "$path" ] || continue
    count=$((count+1))
    printf 'Surviving owner:\n'; cat "$path"
    [ -f "${path%.meta}.pr-poll-registration" ]
  done
  [ "$count" = 1 ]
  printf 'Exactly one durable owner and one armed poll.\n'
done
printf '\nConcurrent ownership remained exclusive; lab removed by EXIT trap.\n'

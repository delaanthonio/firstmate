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

. "$ROOT/bin/fm-wake-lib.sh"
URL=https://github.com/fm-live-validation/disposable/pull/9
for entry in explicit flagless; do
  ID=race-$entry
  META="$LAB/state/$ID.meta"
  if [ "$entry" = flagless ]; then
    printf 'kind=orphan\npr=%s\n' "$URL" > "$META"
    chmod 600 "$META"
    LOCK=$(fm_task_set_lock_path "$LAB/state")
    fm_lock_acquire_wait "$LOCK"
    bin/fm-pr-check.sh "$ID" "$URL" > "$LAB/$entry.out" 2>&1 &
    recording_pid=$!
  else
    bin/fm-pr-check.sh "$ID" "$URL" --orphan > "$LAB/$entry.out" 2>&1 &
    recording_pid=$!
    for ((i=0; i<1000; i++)); do [ ! -f "$META" ] || break; sleep 0.01; done
    [ -f "$META" ]
    LOCK=$(fm_task_set_lock_path "$LAB/state")
    fm_lock_acquire_wait "$LOCK"
  fi
  prepared=false
  for ((i=0; i<2000; i++)); do
    for file in "$LAB/state"/.fm-pr-poll-data.*; do
      [ -f "$file" ] || continue
      prepared=true
      break
    done
    [ "$prepared" != true ] || break
    sleep 0.01
  done
  if [ "$prepared" != true ]; then
    fm_lock_release "$LOCK"
    wait "$recording_pid" || true
    cat "$LAB/$entry.out"
    echo 'SETUP ERROR: could not intercept publication'
    exit 1
  fi
  printf 'kind=ship\nspawn_gen=replacement-worker\n' > "$LAB/replacement"
  chmod 600 "$LAB/replacement"
  cp "$LAB/replacement" "$META"
  printf '\nSCENARIO %s orphan recording refuses a worker replacement at publication\n' "$entry"
  fm_lock_release "$LOCK"
  rc=0
  wait "$recording_pid" || rc=$?
  cat "$LAB/$entry.out"
  printf 'exit=%s\nReplacement metadata:\n' "$rc"
  cat "$META"
  [ "$rc" -ne 0 ]
  grep -q 'was replaced before PR publication' "$LAB/$entry.out"
  cmp "$LAB/replacement" "$META"
  for suffix in check.sh pr-poll pr-poll-registration; do [ ! -e "$LAB/state/$ID.$suffix" ]; done
  echo 'Replacement unchanged; no stale binding or poll published.'
  rm "$META"
done
printf '\nBoth real recorder races refused stale publication; lab removed by EXIT trap.\n'

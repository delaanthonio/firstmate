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
URL=https://github.com/fm-live-validation/disposable/pull/9
refuse() {
  local rc=0
  printf '\nCOMMAND'; printf ' %q' "$@"; printf '\n'
  "$@" > "$LAB/result" 2>&1 || rc=$?
  cat "$LAB/result"
  printf 'exit=%s\n' "$rc"
  [ "$rc" -ne 0 ]
}
printf '\nSCENARIO missing task requires explicit orphan opt-in\n'
refuse bin/fm-pr-merge.sh missing "$URL"
[ ! -e "$LAB/state/missing.meta" ]
printf '\nSCENARIO record and reuse an orphan using the real recorder and real gh without credentials\n'
bin/fm-pr-check.sh orphan-live "$URL" --orphan
cp "$LAB/state/orphan-live.meta" "$LAB/original.meta"
cat "$LAB/state/orphan-live.meta"
bin/fm-pr-check.sh orphan-live "$URL" --orphan
cmp "$LAB/original.meta" "$LAB/state/orphan-live.meta"
[ -f "$LAB/state/orphan-live.check.sh" ] && [ -f "$LAB/state/orphan-live.pr-poll-registration" ]
printf 'Persisted poll identity:\n'; cat "$LAB/state/orphan-live.pr-poll"
printf '\nSCENARIO explicit and flagless recording cannot rebind an orphan\n'
refuse bin/fm-pr-check.sh orphan-live https://github.com/fm-live-validation/disposable/pull/10 --orphan
refuse bin/fm-pr-check.sh orphan-live https://github.com/fm-live-validation/disposable/pull/10
cmp "$LAB/original.meta" "$LAB/state/orphan-live.meta"
printf '\nSCENARIO a new ID cannot bypass existing ownership, including mixed GitHub case\n'
refuse bin/fm-pr-check.sh alternate https://github.com/FM-LIVE-VALIDATION/Disposable/pull/9 --orphan
[ ! -e "$LAB/state/alternate.meta" ]
printf '\nSCENARIO orphan mode preserves an existing worker record\n'
printf 'kind=ship\nspawn_gen=fixture-generation\n' > "$LAB/state/worker.meta"
cp "$LAB/state/worker.meta" "$LAB/worker.before"
refuse bin/fm-pr-check.sh worker https://github.com/fm-live-validation/disposable/pull/11 --orphan
cmp "$LAB/worker.before" "$LAB/state/worker.meta"
[ ! -e "$LAB/state/worker.pr-poll" ]
rm "$LAB/state/worker.meta"
printf '\nSCENARIO forge-only records remain valid without a worker directory or backlog entry\n'
bin/fm-crew-state.sh orphan-live
bin/fm-afk-contract.sh live-workers
bin/fm-fleet-snapshot.sh --secondmate-home-summary > "$LAB/summary.json"
jq '{valid, invalidity}' "$LAB/summary.json"
jq -e '.valid == true' "$LAB/summary.json" >/dev/null
printf '\nSCENARIO captain hold blocks orphan merge before any forge merge\n'
bin/fm-captain-hold.sh hold orphan-live --title 'Disposable orphan validation' --reason 'Do not merge this validation PR'
refuse bin/fm-pr-merge.sh orphan-live "$URL" --orphan
grep -q 'held for the captain' "$LAB/result"
[ ! -e "$LAB/state/orphan-live.merge-authority" ] && [ ! -e "$LAB/state/orphan-live.pr-poll-merge-notified" ]
printf '\nAll live local scenarios completed; lab removed by EXIT trap.\n'

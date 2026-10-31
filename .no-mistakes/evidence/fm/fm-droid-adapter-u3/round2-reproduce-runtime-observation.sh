#!/bin/bash
set -eu
ROOT=$PWD
LAB="$ROOT/.validation-tmp/round2-model-protocol-lab"
bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state"
. "$ROOT/bin/fm-pr-lib.sh"
META="$LAB/state/runtime.meta"
cat > "$META" <<'EOF'
harness=droid
model=default
effective_model=unknown-at-spawn
spawn_gen=live-generation
pr=https://github.com/example/repo/pull/1
pr_head=0123456789012345678901234567890123456789
x_request=runtime-review
EOF
fm_pr_poll_prepare "$LAB/state" runtime github https://github.com/example/repo/pull/1 github.com example/repo 1 "$ROOT/bin/fm-pr-poll.sh"
fm_pr_poll_publish_prepared
fm_pr_poll_artifacts_valid "$LAB/state" runtime "$ROOT/bin/fm-pr-poll.sh"
printf 'Before observation (registered PR poll valid):\n'
cat "$META"
printf '{"model":"glm-5.3-flash","secret":"discard-me"}\n' > "$LAB/session.settings.json"
jq -n --arg path "$LAB/session.jsonl" '{transcript_path:$path}' | bash bin/fm-droid-model.sh observe "$META" live-generation
fm_pr_poll_artifacts_valid "$LAB/state" runtime "$ROOT/bin/fm-pr-poll.sh"
printf '\nAfter observation (registered PR poll still valid):\n'
cat "$META"
[ "$(sed -n 's/^effective_model=//p' "$META")" = glm-5.3-flash ]
[ "$(sed -n 's/^model=//p' "$META")" = default ]
mkdir "$LAB/state/.meta-runtime.lock"
printf '%s\n' "$$" > "$LAB/state/.meta-runtime.lock/pid"
printf '{"model":"custom:updated-accounting"}\n' > "$LAB/session.settings.json"
jq -n --arg path "$LAB/session.jsonl" '{transcript_path:$path}' | bash bin/fm-droid-model.sh observe "$META" live-generation
[ "$(sed -n 's/^effective_model=//p' "$META")" = glm-5.3-flash ]
rm "$LAB/state/.meta-runtime.lock/pid"
rmdir "$LAB/state/.meta-runtime.lock"
bash bin/fm-droid-model.sh reconcile "$META" live-generation
fm_pr_poll_artifacts_valid "$LAB/state" runtime "$ROOT/bin/fm-pr-poll.sh"
printf '\nAfter deferred reconciliation (registered PR poll still valid):\n'
cat "$META"
[ "$(sed -n 's/^effective_model=//p' "$META")" = custom:updated-accounting ]
printf '{"model":"stale-model"}\n' > "$LAB/session.settings.json"
jq -n --arg path "$LAB/session.jsonl" '{transcript_path:$path}' | bash bin/fm-droid-model.sh observe "$META" retired-generation
[ "$(sed -n 's/^effective_model=//p' "$META")" = custom:updated-accounting ]
printf '\nRetired generation observation ignored; selection remains default; PR registration authenticates.\n'

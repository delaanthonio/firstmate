#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
DROID_BIN=$(command -v droid)
REAL_TMUX=$(command -v tmux)
REAL_HOME=$HOME
LAB=$(mktemp -d "$TMPDIR/fm-lab-native.XXXXXX")
SOCKET="fm-lab-native-$$"
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; sleep 1; chmod -R u+w "$LAB"; rm -rf "$LAB"; }
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND TMUX_TMPDIR
mkdir -p "$LAB/user/.factory" "$LAB/shim"
for name in settings.json config.json auth.encrypted auth.v2.file auth.v2.key auth.v2.loginkeychain; do
  [ ! -f "$REAL_HOME/.factory/$name" ] || cp "$REAL_HOME/.factory/$name" "$LAB/user/.factory/$name"
done
jq 'del(.hooks,.trustedFolders,.enabledPlugins)' "$LAB/user/.factory/settings.json" > "$LAB/clean"
mv "$LAB/clean" "$LAB/user/.factory/settings.json"
export HOME="$LAB/user" FM_HOME="$LAB/fleet" TREEHOUSE_ROOT="$LAB/pool" DISABLE_AUTOUPDATER=1
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'tmux\n' > "$FM_HOME/config/backend"
git init -q -b main "$LAB/project"
git -C "$LAB/project" -c user.name=guard -c user.email=guard@local commit -q --allow-empty -m init
"$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s firstmate -x 140 -y 45 -c "$LAB/project" 'bash --noprofile --norc'
export TMUX SHELL
TMUX=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t firstmate '#{socket_path},#{pid},0')
SHELL=$(command -v bash)
"$REAL_TMUX" -L "$SOCKET" set-option -g default-shell "$SHELL"
cat > "$LAB/shim/tmux" <<WRAP
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
WRAP
chmod +x "$LAB/shim/tmux"
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/bin/fm-busy-lib.sh"
mkdir -p "$FM_HOME/data/native"
report="$FM_HOME/data/native/report.md"
printf '# Task\nCalculate 12345 + 67890. Use Execute to write only the sum to "%s" and reply with it. Do not perform other tasks.\n' "$report" > "$FM_HOME/data/native/brief.md"
"$ROOT/bin/fm-spawn.sh" native "$LAB/project" --scout --harness droid --model gpt-6-sol --effort high
TARGET=firstmate:fm-native
capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET"; }
idle() {
  for ((i=0;i<180;i++)); do
    if [ -f "$FM_HOME/state/native.turn-ended" ] && [ "$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")" = empty ] && ! capture | fm_busy_droid_tail_busy; then return 0; fi
    sleep 1
  done
  capture
  return 1
}
idle
[ "$(tr -d '[:space:]' < "$report")" = 80235 ]
jq -e '.sessionDefaultSettings.model == "gpt-6-sol" and .sessionDefaultSettings.reasoningEffort == "high"' "$FM_HOME/state/native.droid-settings.json"
cat "$FM_HOME/state/native.droid-settings.json"
"$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" > "$EVIDENCE/droid-native-completed.ansi"
printf 'NATIVE_MODEL exact-id=gpt-6-sol effort=high response=80235 Stop=observed\n'
# The exact real vendor process is crew-detectable but never a primary lock holder.
tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_tty}')
droid_pid=$(ps -t "${tty#/dev/}" -o pid=,comm= | awk '$2 ~ /(^|\/)droid$/ {print $1; exit}')
[ -n "$droid_pid" ]
printf '%s\n' "$droid_pid" > "$FM_HOME/state/.lock"
lock_state=$("$ROOT/bin/fm-lock.sh" status)
printf 'DROID_LOCK_STATUS %s\n' "$lock_state"
printf '%s' "$lock_state" | grep -q stale
rm "$FM_HOME/state/.lock"
# Verify public exit refuses to overwrite an unsent native composer draft.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'DROID_UNSENT_DRAFT'
sleep 1
if "$ROOT/bin/fm-control.sh" native exit; then echo 'unexpected draft acceptance'; exit 1; fi
capture | grep -q DROID_UNSENT_DRAFT
"$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" > "$EVIDENCE/droid-native-draft.ansi"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-u
for ((i=0;i<30;i++)); do [ "$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")" != empty ] || break; sleep 1; done
printf 'DRAFT_REFUSAL draft-retained=true agent-live=true\n'
# A replacement receives literal native model and changed dynamic effort.
rm "$report" "$FM_HOME/state/native.turn-ended"
"$ROOT/bin/fm-control.sh" native relaunch --model gpt-6-sol --effort dynamic --note 'Repeat the original arithmetic report; do not do other work.'
idle
[ "$(tr -d '[:space:]' < "$report")" = 80235 ]
jq -e '.sessionDefaultSettings.model == "gpt-6-sol" and .sessionDefaultSettings.reasoningEffort == "dynamic"' "$FM_HOME/state/native.droid-settings.json"
printf 'NATIVE_RELAUNCH exact-id=gpt-6-sol effort=dynamic new-response=80235 new-Stop=observed\n'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l /settings
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 1
"$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" > "$EVIDENCE/droid-native-settings.ansi"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape
for ((i=0;i<30;i++)); do [ "$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")" != empty ] || break; sleep 1; done
# Interrupt through the public control plane while the real vendor is busy.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'Use Execute to run sleep 60. Afterwards reply finished. Do not do other work.'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
busy=0
for ((i=0;i<60;i++)); do if capture | fm_busy_droid_tail_busy; then busy=1; break; fi; sleep 1; done
[ "$busy" = 1 ]
"$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" > "$EVIDENCE/droid-native-busy.ansi"
. "$ROOT/bin/fm-backend.sh"
droid_busy=$(fm_busy_classify tmux "$TARGET" droid native "$FM_HOME/state")
other_busy=$(fm_busy_classify tmux "$TARGET" claude native "$FM_HOME/state")
printf 'LIVE_BUSY_SCOPE droid=%s claude=%s\n' "$droid_busy" "$other_busy"
[ "$droid_busy" = 'busy droid-regex' ]
[ "$other_busy" = 'unknown missing' ]
"$ROOT/bin/fm-control.sh" native interrupt
for ((i=0;i<60;i++)); do capture | fm_busy_droid_tail_busy || break; sleep 1; done
if capture | fm_busy_droid_tail_busy; then echo 'public interruption failed'; exit 1; fi
printf 'PUBLIC_INTERRUPT idle=observed vendor-still-live=true\n'
"$ROOT/bin/fm-control.sh" native exit
"$ROOT/bin/fm-captain-hold.sh" complete native --none
"$ROOT/bin/fm-teardown.sh" native
[ ! -e "$FM_HOME/state/native.droid-settings.json" ]
[ ! -e "$FM_HOME/state/native.droid-trust" ]
jq -e '(.trustedFolders // {}) | length == 0' "$HOME/.factory/settings.json"
printf 'NATIVE_TEARDOWN settings=absent receipt=absent exact-trust=absent\n'
# A real background vendor executable cannot make a foreground shell controllable.
cat > "$LAB/background.sh" <<'BG'
#!/usr/bin/env bash
set -m
"$DROID_BIN" --settings "$LAB/background-settings.json" &
printf '%s\n' "$!" > "$LAB/background.pid"
cat "$EVIDENCE/droid-native-completed.ansi"
printf '\033[43;1H'
while IFS= read -r text; do printf '%s\n' "$text" >> "$LAB/control-input"; done
BG
printf '{}\n' > "$LAB/background-settings.json"
export LAB DROID_BIN EVIDENCE
"$REAL_TMUX" -L "$SOCKET" new-window -t firstmate -n background -c "$LAB/project" "bash --noprofile --norc '$LAB/background.sh'"
TARGET=firstmate:background
for ((i=0;i<60;i++)); do [ ! -s "$LAB/background.pid" ] || break; sleep 0.1; done
tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_tty}')
for ((i=0;i<60;i++)); do
  ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= > "$LAB/processes"
  awk '$2 != $3 && $4 ~ /(^|\/)droid$/ {found=1} END {exit !found}' "$LAB/processes" && break
  sleep 0.1
 done
cat "$LAB/processes"
awk '$2 != $3 && $4 ~ /(^|\/)droid$/ {found=1} END {exit !found}' "$LAB/processes"
if PATH="$LAB/shim:$PATH" fm_tmux_pane_is_droid "$TARGET"; then echo 'background Droid claimed foreground'; exit 1; fi
verdict=$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")
[ "$verdict" = unknown ]
printf 'BACKGROUND_COMPOSER verdict=%s exact-vendor-background=true\n' "$verdict"
printf 'window=%s\nworktree=%s\nproject=%s\nkind=scout\nharness=droid\n' "$TARGET" "$LAB/project" "$LAB/project" > "$FM_HOME/state/background.meta"
rc=0
"$ROOT/bin/fm-control.sh" background exit || rc=$?
[ ! -s "$LAB/control-input" ]
printf 'BACKGROUND_CONTROL exit=%s no-control-input=true\n' "$rc"
# Stop only this disposable process before removing its private home.
kill -KILL "$(cat "$LAB/background.pid")" 2>/dev/null || true

# Droid primary verification

This is the maintainer-verification record for Droid's primary-session adapter.
The reusable contract lives in [the harness-adapters skill](../../.agents/skills/harness-adapters/SKILL.md), [the turn-end guard](../turnend-guard.md), [the arm seatbelt](../arm-pretool-check.md), and [the Droid supervision protocol](../supervision-protocols/droid.md).

## Environment

Date: 2026-08-29.
Platform: macOS arm64, tmux.
The installed CLI advanced from 0.205.1 to 0.208.1 during the verification window.
Every primary guarantee below was established or re-established on the final 0.208.1 binary.

```sh
command -v droid
droid --version
```

```text
/Users/dela/.local/bin/droid
0.208.1
```

All scratch settings used the same project-level hook schema now tracked in `.factory/settings.json`.
The live probes ran in a disposable task worktree and a nested scratch Git repository.

## Stop blocking and loop guard

The probe command was:

```sh
tmux new-session -d -s fm-droid-primary-stopfinal -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-stop-loop-guard.json' --auto high 'Reply with exactly LOOP_READY, then end your turn.'"
```

The Stop command appended stdin, returned 2 with `DROID_STOP_INITIAL_BLOCK` when `stop_hook_active` was false, and returned 0 with `DROID_STOP_ACTIVE_ALLOW` when it was true.
The exact relevant pane output was:

```text
⛬  LOOP_READY

   DROID_STOP_INITIAL_BLOCK

⛬  Captain, shipshape.

   Hooks Stop
    └─ bash .droid-primary-lab/stop-loop-guard... : Exit code 0
      └─ DROID_STOP_ACTIVE_ALLOW
```

The exact payload log was:

```json
{"session_id":"5974f925-4ac8-4f28-9ed7-3aeda2c73d57","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/5974f925-4ac8-4f28-9ed7-3aeda2c73d57.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-high","hook_event_name":"Stop","message_id":"mcp-auth-status-4f68e43e-4372-4088-9a61-145f0c368426","stop_hook_active":false,"tool_execution_count":0,"elapsed_time":0}
{"session_id":"5974f925-4ac8-4f28-9ed7-3aeda2c73d57","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/5974f925-4ac8-4f28-9ed7-3aeda2c73d57.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-high","hook_event_name":"Stop","message_id":"596f3bba-992e-41c7-9cdb-4c3d5f7e45c6","stop_hook_active":true,"tool_execution_count":0,"elapsed_time":0}
```

Result: exit 2 plus stderr blocks the first Stop, forces a continuation, and the forced continuation carries `stop_hook_active: true`.
The shared default one-block guard is therefore the verified loop bound.

## PreToolUse denial

An allow probe first established Droid's native tool name and payload.

```sh
tmux new-session -d -s fm-droid-primary-prelog -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-pretool-log.json' --auto high 'Use a shell tool to run exactly: touch .droid-primary-lab/pretool-allowed-sentinel. Then report DONE.'"
```

```json
{"session_id":"8d9dc6ac-89f0-4fee-99a2-08484dfb3355","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/8d9dc6ac-89f0-4fee-99a2-08484dfb3355.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-medium","hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"touch .droid-primary-lab/pretool-allowed-sentinel","summary":"Create requested sentinel file","riskLevelReason":"This command creates or updates one explicitly requested sentinel file inside the workspace and does not affect other files.","riskLevel":"medium"}}
```

The allowed sentinel was `PRESENT`.
A plain-stderr exit-2 probe produced:

```text
Hooks PreToolUse → 1 failed
 DROID_PLAIN_STDERR_DENY
Execute touch .droid-primary-lab/pretool-plain-sentinel
 ↳ Error: DROID_PLAIN_STDERR_DENY

Captain, exact denial: DROID_PLAIN_STDERR_DENY

--- sentinel ---
ABSENT
```

The production checker was then exercised unchanged:

```sh
tmux new-session -d -s fm-droid-primary-prereal -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-pretool-real.json' --auto high 'Use a shell tool to run exactly: bin/fm-watch-arm.sh &. Do not alter the command. Report whether the tool ran or was denied.'"
pgrep -fl '/Users/dela/.treehouse/firstmate-395343/1/firstmate/bin/fm-watch.sh' || printf '%s\n' NONE
```

```text
Hooks PreToolUse → 1 failed
 {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDeci...
Execute bin/fm-watch-arm.sh &
 ↳ Error: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permi...

Captain, the command was denied by a safety hook because it backgrounds a
protected watcher command.

--- watcher processes scoped to this root ---
NONE
```

Result: `.tool_input.command` under tool name `Execute` is the verified transport.
Exit 2 plus nonempty stderr is sufficient to deny before execution.
The unchanged checker is honored even though its default mode also emits the Grok decision object on stdout.

## Persistent project settings and SessionStart

A nested scratch Git repository carried `.factory/settings.json` and was launched without `--settings`:

```sh
git init .droid-primary-lab/project-settings
tmux new-session -d -s fm-droid-primary-project \
  -c "$PWD/.droid-primary-lab/project-settings" \
  "droid --auto high 'Reply with exactly PROJECT_OK and end your turn.'"
```

```text
⛬  PROJECT_OK

   Hooks Stop
    └─ bash .factory/project-stop.sh : Exit code 0
      └─ PROJECT_SETTINGS_STOP_FIRED
```

The exact payload began:

```json
{"session_id":"230f215c-29ef-4974-bdbc-20f230ad45f2","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate-.droid-primary-lab-project-settings/230f215c-29ef-4974-bdbc-20f230ad45f2.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate/.droid-primary-lab/project-settings","permission_mode":"auto-medium","hook_event_name":"Stop","message_id":"1ebb0f0a-120a-4bcd-9346-1c242be6ec11","stop_hook_active":false,"tool_execution_count":0,"elapsed_time":0}
```

SessionStart context delivery was tested with:

```sh
tmux new-session -d -s fm-droid-primary-sessionstart -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-sessionstart.json' --auto high 'Before doing anything else, repeat any DROID_SESSIONSTART_CONTEXT_TOKEN value already injected into your context. If none exists, say NONE.'"
```

```text
⛬  Captain, DROID_SESSIONSTART_CONTEXT_TOKEN_8291
```

```json
{"session_id":"0e618d00-adba-49b1-bc71-fe62f22a370b","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/0e618d00-adba-49b1-bc71-fe62f22a370b.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-high","hook_event_name":"SessionStart","source":"startup","CLAUDE_ENV_FILE":"/Users/dela/.factory/temp/env/droid-env-0e618d00-adba-49b1-bc71-fe62f22a370b.sh"}
```

Result: `.factory/settings.json` is persistent project configuration for a normal invocation, and SessionStart stdout is injected into model context.
The hook environment included these exact root bindings:

```text
CLAUDE_PROJECT_DIR=/Users/dela/.treehouse/firstmate-395343/1/firstmate
DROID_PROJECT_DIR=/Users/dela/.treehouse/firstmate-395343/1/firstmate
FACTORY_PROJECT_DIR=/Users/dela/.treehouse/firstmate-395343/1/firstmate
PWD=/Users/dela/.treehouse/firstmate-395343/1/firstmate
```

## Foreground tool behavior

The probe launched Droid with a request to run a foreground loop and continue reasoning visibly during execution.
Captures were taken while the tool was running and after it finished.

```text
--- capture t+12 ---
⛬  Captain, I’m running the exact command in the foreground now. If the
   interface allows updates during execution, I’ll continue visibly.

   Execute bash -lc 'for i in 1 2 3 4 5 6; do echo FOREGROUND_TICK_; s...
    ↳ FOREGROUND_TICK_

 ⡄ Executing...  (Press ESC to stop)
```

```text
--- capture t+22 ---
⛬  Captain, I’m running the exact command in the foreground now. If the
   interface allows updates during execution, I’ll continue visibly.

   Execute bash -lc 'for i in 1 2 3 4 5 6; do echo FOREGROUND_TICK_; s...
    ↳ FOREGROUND_TICK_

 ⠘ Executing...  (Press ESC to stop)
```

```text
--- capture t+34 ---
   Execute bash -lc 'for i in 1 2 3 4 5 6; do echo FOREGROUND_TICK_; s...
    ↳ FOREGROUND_TICK_
      FOREGROUND_TICK_
      FOREGROUND_TICK_
      FOREGROUND_TICK_
    ... 2 more, Ctrl+O to view

⛬  Captain, FOREGROUND_FINISHED.
```

Result: no new reasoning appeared between the two running captures; the next model output appeared only after the foreground tool completed.
Droid therefore uses bounded foreground watcher checkpoints.

## Busy and composer signatures

The busy capture contained:

```text
⠘ Executing...  (Press ESC to stop)
```

Thinking used the same stable token:

```text
⢠ Thinking...  (Press ESC to stop)
```

The idle composer and the busy placeholder were:

```text
╭──────────────────────────────────────────────────────────────────────────────╮
│ >                                                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
```

```text
╭──────────────────────────────────────────────────────────────────────────────╮
│ > Enter to steer · Ctrl+Enter to queue                                       │
╰──────────────────────────────────────────────────────────────────────────────╯
```

Tmux reported:

```sh
tmux display-message -p -t fm-droid-primary-foreground \
  'cursor_y=#{cursor_y} cursor_x=#{cursor_x} cursor_flag=#{cursor_flag} pane_tty=#{pane_tty} pane_pid=#{pane_pid}'
```

```text
cursor_y=21 cursor_x=0 cursor_flag=0 pane_tty=/dev/ttys017 pane_pid=44448
```

The foreground process group contained an exact `droid` process even though tmux's current command was the launching `fish` shell.
After teaching the shared screen owner the elapsed-time footer and gating tmux's cursorless read on that exact process identity, the live checks were:

```text
droid_identity=yes
idle_verdict=empty
typed_verdict=pending
```

The placeholder is de-emphasized in the styled capture and real typed text is bright.
No other idle ghost or placeholder was observed.

## Refresh

Run the opt-in guard after a Droid upgrade:

```sh
FM_DROID_PRIMARY_LIVE_E2E=1 tests/fm-droid-primary-live-e2e.test.sh
```

If any required fact cannot be reproduced, leave Droid's primary status unverified rather than substituting another harness's behavior.

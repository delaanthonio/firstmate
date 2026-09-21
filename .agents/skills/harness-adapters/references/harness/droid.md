# Droid

Verified for crewmate, scout, secondmate, and primary work with Droid CLI 0.38.0 on 2026-07-03.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `droid`. |
| Launch | Positional instructions with `--settings state/<id>.droid-settings.json --auto high`; foreign primary markers are cleared. |
| Busy state | Adapter-scoped rendered fallback matching only the verified `Press ESC to stop` working footer. |
| Exit command | `/quit`. |
| Interrupt | Single Escape. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`. |
| Resume | No verified native pane resume; use deterministic relaunch. |
| Autonomy | `--auto high`, labeled `Auto (High) · allow all commands`. |
| Trust | No verified workspace-trust dialog. |
| Marker | Exact `droid` process ancestry; Droid exposes no stable environment identity marker. |
| Model | Per-task settings key `model.customModel`. |
| Effort | Per-task settings key `reasoningEffort`; `dynamic` omits the key. |
| Composer | Two-line bordered box; hints may appear on the right side of the first row. |

## Detection and control

`../../../../../bin/fm-harness.sh` accepts only an exact `droid` ancestor.
Control uses Escape for interrupt and `/quit` for exit.
`../../../../../bin/fm-session-lock-lib.sh` and `../../../../../bin/fm-agent-process-lib.sh` recognize the same exact process identity.

## Launch settings

`../../../../../bin/fm-spawn.sh` writes `state/<id>.droid-settings.json` before endpoint allocation and launches Droid with that file through `--settings`.
The settings file carries the crewmate turn-end hook plus optional model and reasoning-effort pins.
It is task-local runtime state and `../../../../../bin/fm-teardown.sh` removes it.

## Primary integration

Tracked `.factory/settings.json` registers SessionStart, Execute PreToolUse, AskUser PreToolUse, and Stop hooks.
SessionStart runs `../../../../../bin/fm-session-start.sh`.
Execute uses the shared primary seatbelt, AskUser defers captain-bound approval questions during away mode, and Stop invokes the Droid turn-end guard.
The `/afk` skill owns the required question binding, and `../../../../../bin/fm-captain-hold.sh` preserves and projects the exact question through its existing owner.
`../../../../../docs/supervision-protocols/droid.md` owns the primary foreground-checkpoint procedure.

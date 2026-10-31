# Droid

Verified for crewmate, scout, secondmate, and primary work; versioned evidence lives in [`docs/verification/droid-primary.md`](../../../../../docs/verification/droid-primary.md) and [`docs/verification/fork-sync-droid-2026-08-18.md`](../../../../../docs/verification/fork-sync-droid-2026-08-18.md).
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
| Trust | Fresh folders require approval; the spawn gate answers the affirmative selection and confirms brief processing. |
| Marker | Exact `droid` process ancestry; Droid exposes no stable environment identity marker. |
| Model | Per-task settings key `sessionDefaultSettings.model`; custom models use their registry id. |
| Effort | Per-task settings key `sessionDefaultSettings.reasoningEffort`; `dynamic` is retained. |
| Composer | Two-line bordered box; hints may appear on the right side of the first row. |
| Background execution | Native tracked Execute jobs (`fireAndForget: true`) exist; completion re-invokes the primary agent with the job output (verified 2026-10-31). |

## Detection and control

`../../../../../bin/fm-harness.sh` accepts only an exact `droid` ancestor.
Control uses Escape for interrupt and `/quit` for exit.
`../../../../../bin/fm-session-lock-lib.sh` and `../../../../../bin/fm-agent-process-lib.sh` recognize the same exact process identity.

## Launch settings

`../../../../../bin/fm-spawn.sh` writes `state/<id>.droid-settings.json` before endpoint allocation and launches Droid with that file through `--settings`.
The settings file carries the crewmate turn-end hook plus optional model and reasoning-effort pins.
It is task-local runtime state and `../../../../../bin/fm-teardown.sh` removes it.
When the model is omitted or `default`, spawn observes the user and worktree settings for the task's `model=` record without adding a model override to the runtime settings.
An unresolved product default remains `default`; spawn never substitutes a different model for accounting.
`../../../../../bin/fm-spawn.sh` owns the folder-trust gate, its bounded wait, and the refusal on backends without verified viewport capture.
Factory's [settings reference](https://docs.factory.com/droid-cli/settings) documents no settings-based folder-trust bypass, so spawn uses the verified control-plane answer instead of writing an undocumented trust store.

## Working style

Droid works programmatically and may use scripts for implementation, analysis, and other task work.
Steering responses and validation-gate decisions remain agent actions on the doorbell plane: read the delivered instruction, reason about it, and respond through the required interface.
Never move those lifecycle decisions into scripts that read an inbox or answer gates autonomously.

## Primary integration

Tracked `.factory/settings.json` registers SessionStart, Execute PreToolUse, AskUser PreToolUse, and Stop hooks.
SessionStart runs `../../../../../bin/fm-session-start.sh`.
Execute uses the shared primary seatbelt, AskUser defers captain-bound approval questions during away mode, and Stop invokes the Droid turn-end guard.
The `/afk` skill owns the required question binding, and `../../../../../bin/fm-captain-hold.sh` preserves and projects the exact question through its existing owner.
`../../../../../docs/supervision-protocols/droid.md` owns the primary tracked background-cycle procedure and foreground checkpoint fallback.

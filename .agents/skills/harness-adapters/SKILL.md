---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, and droid.
user-invocable: false
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
The captain may override that file at bootstrap or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Each adapter splits into mechanics and knowledge.
The mechanics, including launch command, autonomy flag, and turn-end hook, live in `bin/fm-spawn.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` names an unverified adapter, tell the captain and fall back to firstmate's own harness until that adapter is verified.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override, and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness`.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.
Not every harness exports an env marker: claude (`CLAUDECODE=1`) and pi (`PI_CODING_AGENT=true`) do, but codex, opencode, and droid export none to tool subprocesses and are detected purely by the `droid`/`codex`/`opencode` command name in the process ancestry.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- droid: `/<skill>`, for example `/no-mistakes`; droid imports `~/.claude/skills`, so the same user-level skills claude sees are available and `/no-mistakes` is present (verified in its slash palette), meaning a droid crewmate can drive the no-mistakes pipeline itself.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it with `bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, and verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the pane reader in `bin/fm-tmux-lib.sh` captures only the composer line with ANSI styling, drops dim/faint SGR 2 runs, and ignores them, so only normal-intensity typed text counts as pending input.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `fm-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.3)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

## pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no `esc to interrupt` text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
Keep the brief as one positional argument.
Multiple positional args become separate queued messages; `fm-spawn`'s template already does this correctly.

Project trust dialog can appear on the first pi run in any not-yet-trusted directory, observed even on clean worktrees.
Accept with Enter.
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it.

`fm-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse and pollute the project.
The extension must listen for pi's `turn_end` event, not `agent_end`, so the watcher wakes after each completed turn instead of only when the whole agent run exits.
Pi sets `PI_CODING_AGENT=true` for its children; this is its harness-detection env marker.

## droid (VERIFIED 2026-06-27, droid 0.159.1)

| Fact | Value |
|---|---|
| Busy-pane signature | `Press ESC to stop` (constant tail of its working footer, e.g. `⠋ Streaming...  (Press ESC to stop)`, `Invoking tools...`, `Executing...`; the verb varies, the parenthetical is constant) |
| Exit command | `/quit` ("Exit from the Droid CLI"; returns to the shell and prints a `droid --resume <id>` hint) |
| Interrupt | single Escape (the footer literally reads "Press ESC to stop"; shows `Interrupted` / `Request cancelled by user`) |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`); droid imports `~/.claude/skills`, so user-level skills are available and droid can drive no-mistakes itself |

Factory's droid CLI. Launch is `droid --auto high "$(cat <brief>)"`; `--auto high` is the autonomy level (footer `Auto (High) · allow all commands`), the analog of claude's `--dangerously-skip-permissions`, and it runs every tool with no per-action permission prompt.
Keep the brief as one positional argument; a single quoted prompt is processed as one message (no multi-arg splitting).
The interactive TUI stays alive after a turn, idling in the composer, so firstmate steers it with `fm-send` exactly like the other harnesses.
Mid-turn, Enter steers the running turn and Ctrl+Enter queues; the composer's `Enter to steer · Ctrl+Enter to queue` placeholder is dim/ghost text, and `fm-tmux-lib.sh`'s composer reader correctly reads a busy or idle droid pane as empty, so no `FM_COMPOSER_IDLE_RE` override is needed.

No trust or permission dialog appears on first run in a fresh worktree when droid is already authenticated; authentication and trust persist globally under `~/.factory/`, not per-directory, so later worktrees never re-prompt.
On an unauthenticated machine a login prompt can appear instead, so still peek the pane after spawn like any other harness.

droid auto-updates in the background, like opencode: a launch can upgrade the binary mid-stream (observed 0.156.2 → 0.159.1) and the running TUI keeps working on the version it started.
Treat the recorded version as a floor, and re-verify if a launch reports a much newer one.
The default model is `claude-opus-4-8`; a machine may pin a different model (e.g. a local `gpt-5.5` via a custom provider) through `~/.factory/settings.json`, which is captain environment, not an adapter fact.

Resume after exit with `droid --resume <session-id>` (or bare `droid -r` for the last session); the id is printed on `/quit`.

droid exports no dedicated harness-identification env var to tool subprocesses (no `DROID_*`/`FACTORY_*` marker survives into a shell it spawns; `DROID_PROJECT_DIR`/`FACTORY_PROJECT_DIR` exist only inside hook execution).
So, like codex and opencode, it is detected by the `droid` command name in the process ancestry, not an env marker.

Turn-end hook: droid implements the full claude-style hook system, including a `Stop` hook that fires when it finishes responding (and not on a user interrupt) - the per-turn turn-end signal the watcher needs.
`fm-spawn` installs it by writing a settings file to `state/<id>.droid-settings.json`, OUTSIDE the worktree like pi's extension, and launching with `droid --settings <that-file>`, which merges the hook on top of the user's global `~/.factory` settings for that process only.
The file carries `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch <turn-ended-file>"}]}]}}`; verified to fire on every turn (exit 0) and cleaned up by `fm-teardown`.

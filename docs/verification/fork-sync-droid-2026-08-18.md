# Fork sync and Droid preservation verification

Date: 2026-08-18.

## History integrated

The synchronization branch started from `origin/main` at `5540c3dfc0e7f00f23ddea073f616c1ea1f871d8`.
The normal merge commit `5c4a7e0` integrated `upstream/main` at `64d61aed84373e02b1a28c4e6b262908ed8128d5`.
The merge parents are exactly `5540c3dfc0e7f00f23ddea073f616c1ea1f871d8` and `64d61aed84373e02b1a28c4e6b262908ed8128d5`.
No rebase, history rewrite, force update, or fork-only commit removal occurred.
The preserved fork-only commits are `3079e87`, `12542db`, `9db5b56`, and `5540c3d`.

## Conflicts resolved

The merge conflicted in `.agents/skills/afk/SKILL.md`, `.agents/skills/harness-adapters/SKILL.md`, `AGENTS.md`, `README.md`, `bin/fm-harness.sh`, `bin/fm-lock.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-tmux-lib.sh`, `bin/fm-watch.sh`, and `docs/configuration.md`.
Each conflict used the current upstream architecture as its baseline, followed by an explicit Droid capability restoration and a repository-wide verified-harness allowlist audit.

## Complete branch audit

The complete pre-publication audit used `git diff --name-status origin/main..HEAD`, `git diff --stat origin/main..HEAD`, and `git diff origin/main..HEAD` so the inspected range included both the imported upstream baseline and the fork-specific reconciliation.
The inspected range spanned agent contracts, harness integrations, hooks, runtime backends, operator and maintainer documentation, workflows, and tests.
The audit reconciled the verified-harness inventories in `AGENTS.md`, `.agents/skills/harness-adapters/SKILL.md`, `docs/configuration.md`, `docs/architecture.md`, `docs/remote-secondmates.md`, `docs/trace-context.md`, and the runtime-backend guides against the executable allowlists and focused tests.
The fork-specific overlay was separately inspected with `git diff 64d61aed84373e02b1a28c4e6b262908ed8128d5..HEAD`.

## Droid capability inventory

- Harness detection and resolution remain in `bin/fm-harness.sh`, including markerless `droid` process-ancestry detection.
- Session-lock and tmux liveness identity remain in `bin/fm-session-lock-lib.sh` and `bin/backends/tmux.sh`.
- Local and remote spawn allowlists remain in `bin/fm-spawn.sh`, `bin/fm-remote-doctor.sh`, and `bin/fm-remote-secondmate-control.sh`.
- Every template-backed Droid ship, scout, and secondmate launch retains `droid --settings <state-file> --auto high <brief>`.
- The per-task `state/<id>.droid-settings.json` file carries model and effort overrides for every template-backed Droid launch, including `dynamic` effort through local relaunch and remote secondmate recovery.
- The same settings file carries the Stop hook for ships and scouts, while secondmate settings omit hooks.
- Droid settings cleanup remains in `bin/fm-control-lib.sh` and `bin/fm-teardown.sh`.
- Interrupt, exit, relaunch, and task-kind capabilities remain in `bin/fm-control-lib.sh`.
- The verified `Press ESC to stop` delivery token remains in `bin/fm-composer-lib.sh`.
- Droid worker busy state remains an adapter-scoped rendered fallback in `bin/fm-busy-lib.sh`, never a cross-harness regex.
- The bootstrap dispatch validator accepts `droid` and rejects unsupported Droid effort values in `bin/fm-bootstrap.sh`.
- The local secondmate-liveness recovery allowlist accepts both `droid` and the already-verified `cursor` adapter in `bin/fm-bootstrap.sh`.
- Operator and maintainer guidance remains in `AGENTS.md`, `README.md`, `docs/configuration.md`, `docs/agent-control.md`, `docs/architecture.md`, `docs/remote-secondmates.md`, `docs/trace-context.md`, the runtime-backend guides, `.agents/skills/afk/SKILL.md`, and `.agents/skills/harness-adapters/SKILL.md`.
- Focused coverage remains in `tests/fm-bootstrap.test.sh`, `tests/fm-secondmate-liveness.test.sh`, `tests/fm-control.test.sh`, `tests/fm-control-relaunch.test.sh`, `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`, `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-composer-ghost.test.sh`, `tests/fm-busy-state.test.sh`, and `tests/fm-busy-adapter-wiring.test.sh`.

The valid Droid dispatch-profile regression produces no `CREW_DISPATCH: invalid ... unverified harness: droid` diagnostic.

## Baseline validation failures

Clean snapshots were produced with `git archive <ref> | tar -x` and tested under the same account, shell, PATH, tmux binary, and environment as the merge branch.
Clean `origin/main` reproduced the tmux smoke portability defect under fish, first on the bash-specific `PS1=` assignment and then on the bash-specific `for` loop.
Clean `origin/main` did not contain `tests/fm-on.test.sh`, because remote secondmate transport arrived later upstream.
Clean `upstream/main` reproduced the tmux smoke failure at its bash-specific setup command.
Clean `upstream/main` also reproduced the child-PATH ordering mismatch because `compgen -G` returned manager directories in a nondeterministic order while the contract expected deterministic lexical order.
These were repository defects exposed by this host rather than merge-only changes or defensible environment skips.

Commit `58b7f83` made the tmux smoke commands portable across bash, zsh, and fish, sorted glob-discovered PATH directories under `LC_ALL=C`, added a controlled lexical-order regression, and refreshed the remote-doctor checksum after the Droid allowlist change.

## Validation results

- `while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/fm-lint.sh --list-files)` passed.
- `bin/fm-lint.sh` passed with ShellCheck 0.11.0 and actionlint 1.7.12.
- The focused Droid regression set passed.
- `tests/fm-backend-tmux-smoke.test.sh` passed after the shell-portability fix.
- `tests/fm-on.test.sh` passed after deterministic PATH ordering and the checksum refresh.
- `tests/fm-remote-job.test.sh` passed with the new controlled ordering regression.
- `bin/fm-test-run.sh --all` passed all 147 tests, with 20 expected opt-in or optional-tool gate skips and zero failures.
- The `CLAUDE.md` pointer and `.claude/skills` symlink invariants passed.

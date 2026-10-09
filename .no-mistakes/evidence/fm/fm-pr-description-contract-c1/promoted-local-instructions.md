Your scout task has been promoted to a ship task, mode=local-only. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Improve the fixture project PR description.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-local` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-local`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=local-only.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to any remote and never open a PR. Work only on your `fm/promote-local` branch; firstmate handles the merge into local `main`.

# UI screenshot contract
If the change alters a user-visible web page, mobile screen, desktop window, or email template, capture before and after screenshots.
Save both files under `/Users/dela/.no-mistakes/worktrees/51f31747dab7/01M4FNKN7PFEGXMT8J21KMYYAQ/.nm-test-pr-contract/home-local/data/promote-local/shots/`, never commit them to the repo, and append `done: ready in branch fm/promote-local; screenshots: /Users/dela/.no-mistakes/worktrees/51f31747dab7/01M4FNKN7PFEGXMT8J21KMYYAQ/.nm-test-pr-contract/home-local/data/promote-local/shots/` so firstmate can relay them for review.
This mode has no PR, so do not embed the screenshots in a PR description.
The screenshot destination above is the task-authorized exception to any earlier task-kind restriction on outside-worktree writes.
Use the shared automation browser, `chrome-devtools-axi`, for web UI.
For native UI, use surface-specific capture: iOS simulator screenshots via `xcrun`, native desktop window capture, or programmatic evidence when no display is available.
Capture only with seeded fixture or demo accounts.
Redact any real identifier before uploading or otherwise sharing evidence, and never attach an unredacted image to a PR in a public repository.
For a non-UI change, skip screenshots and append `done: ready in branch fm/promote-local; no user-visible change - screenshots not applicable`.

# Definition of done
Delivery contract: mode=local-only
Before reporting done, make the change beautiful: match surrounding style and naming, remove dead code, choose the right abstraction level, keep comments and docstrings evergreen, and run the project's formatter.
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/promote-local`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/promote-local` with any evidence suffix required by the task instructions to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.

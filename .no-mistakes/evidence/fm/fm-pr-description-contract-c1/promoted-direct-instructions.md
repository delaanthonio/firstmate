Your scout task has been promoted to a ship task, mode=direct-PR. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Improve the fixture project PR description.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-direct` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-direct`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=direct-PR.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch (push only your `fm/promote-direct` branch). Never merge a PR.

# PR description contract
When this task opens or updates a PR, whether directly in direct-PR mode or through the no-mistakes pipeline, you own the quality of its description.
Use a conventional-commit PR title with the repository's scope convention.
If `.github/PULL_REQUEST_TEMPLATE.md` exists, follow its section layout instead of the default below while keeping all brevity, content, voice, evidence, and rendering constraints in this contract.
Otherwise, use explicitly titled sections in this order: "Summary", "Screenshots" (for UI changes), "What changed", "How to review", "Testing", "Risk", and "Follow-ups".
Write the Summary as 3-4 plain-language sentences understandable to a non-engineer, explaining the problem and resulting behavior.
For UI changes, place Screenshots near the top with the before and after evidence required below, including when following a repository template.
Keep What changed to short grouped bullets, How to review to 3-5 concrete checks, and Testing to one short list of checks and results.
Keep Risk and Follow-ups brief and explicit; state when there are none rather than inventing concerns or work.
Write for a reader who has not seen the diff, with no filler or restated commit lists.
Keep visible content short, targeting fewer than about 120 lines.
If supplemental evidence is included, put it (including any raw logs, JSON, transcripts, and pipeline output) inside a single collapsed `<details>` block with `<summary>Validation details</summary>`, after the visible sections; never paste it outside that block.
Omit the block when there is no supplemental evidence.
Use a neutral voice: no first-person narration and no direct address of anyone.
Leave a blank line before and after every `<details>`, `</details>`, and `<summary>Validation details</summary>` line and every opening or closing fenced code block, including after an image line.
Use plain characters rather than HTML entities.
Before saving a new or updated description, render the exact proposed body with `gh api markdown -F text=@body.md -f mode=gfm` and inspect the rendered result: any included details block must collapse, and no literal `<details>` / `<summary>` tags or HTML entity text may appear as visible text.

# UI screenshot contract
If the change alters a user-visible web page, mobile screen, desktop window, or email template, capture before and after screenshots and embed them in the PR description before reporting done.
Use the shared automation browser, `chrome-devtools-axi`, for web UI.
For native UI, use surface-specific capture: iOS simulator screenshots via `xcrun`, native desktop window capture, or programmatic evidence when no display is available.
Capture only with seeded fixture or demo accounts.
Redact any real identifier before uploading or otherwise sharing evidence, and never attach an unredacted image to a PR in a public repository.
Attach each image by converting base64 to a File and dispatching a native drop event on the GitHub description textarea; file inputs and synthetic drags do not work.
Verify the saved description renders the `user-attachments` image URLs, then remove every task-created screenshot file from the worktree so teardown stays clean; never commit screenshot files to the repo.
For a non-UI change, skip screenshots and include the exact sentence `no user-visible change - screenshots not applicable` both in every done status line and in the PR description's explicitly titled "Testing" section (or the repository template's equivalent testing section).

# Definition of done
Delivery contract: mode=direct-PR
Before reporting done, make the change beautiful: match surrounding style and naming, remove dead code, choose the right abstraction level, keep comments and docstrings evergreen, and run the project's formatter.
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url} - {summary}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.

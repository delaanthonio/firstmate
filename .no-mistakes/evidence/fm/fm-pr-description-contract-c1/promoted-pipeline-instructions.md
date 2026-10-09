Your scout task has been promoted to a ship task, mode=no-mistakes. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Improve the fixture project PR description.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-pipeline` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-pipeline`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=no-mistakes.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch. Never merge a PR.

The no-mistakes ask-user escalation below supersedes the scout rule 6 escalation shape.
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to `/Users/dela/.no-mistakes/worktrees/51f31747dab7/01M4FNKN7PFEGXMT8J21KMYYAQ/.nm-test-pr-contract/home-pipeline/data/promote-pipeline/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=/Users/dela/.no-mistakes/worktrees/51f31747dab7/01M4FNKN7PFEGXMT8J21KMYYAQ/.nm-test-pr-contract/home-pipeline/data/promote-pipeline/nm-<run>-findings.txt`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.

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
If the change alters a user-visible web page, mobile screen, desktop window, or email template, capture before and after screenshots before appending the implementation-ready `done: {summary}` status that starts the no-mistakes pipeline.
Before appending the final PR-ready `done: PR {url} checks green - {summary}` status, refresh the after screenshot if any pipeline-authored change affected the rendered UI so the evidence represents the shipped result, then embed both current screenshots in the PR description.
Use the shared automation browser, `chrome-devtools-axi`, for web UI.
For native UI, use surface-specific capture: iOS simulator screenshots via `xcrun`, native desktop window capture, or programmatic evidence when no display is available.
Capture only with seeded fixture or demo accounts.
Redact any real identifier before uploading or otherwise sharing evidence, and never attach an unredacted image to a PR in a public repository.
Attach each image by converting base64 to a File and dispatching a native drop event on the GitHub description textarea; file inputs and synthetic drags do not work.
Verify the saved description renders the `user-attachments` image URLs, then remove every task-created screenshot file from the worktree so teardown stays clean; never commit screenshot files to the repo.
For a non-UI change, skip screenshots and include the exact sentence `no user-visible change - screenshots not applicable` both in every done status line and in the PR description's explicitly titled "Testing" section (or the repository template's equivalent testing section).

# Definition of done
Delivery contract: mode=no-mistakes
Before reporting done, make the change beautiful: match surrounding style and naming, remove dead code, choose the right abstraction level, keep comments and docstrings evergreen, and run the project's formatter.
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll `no-mistakes axi status` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green - {summary}` and stop. You are finished.

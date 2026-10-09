# PR instruction contract - product evidence

The real `bin/fm-brief.sh` was executed with an isolated `FM_HOME` for no-mistakes, direct-PR, and local-only tasks. `bin/fm-promote.sh` was then executed for seeded scouts in all three modes. Each printed delivery command was executed against the real `bin/fm-send.sh` and a separate tmux server with a 120x40 terminal grid. The private socket, home, and configuration all lived inside the worktree.

The delivered inbox body matched `ship-instructions.md` exactly (ignoring the shell command substitution's final newline). The current delivery contract also remained in the persisted relaunch brief. Local-only tasks, scouts, and secondmate charters did not receive a PR description contract.

No model interpretation or actual GitHub PR rendering was evaluated: this change supplies worker instructions and does not implement a PR-body validator. These artifacts show the emitted instructions and their delivery.

The existing focused contract test failed against the base commit's executable brief generator and passed against the target. The initial disposable driver compared the entire promotion message against the relaunch brief, which is not the persistence contract; it was corrected to compare the current delivery contract, then the live checks were re-run from a fresh disposable home.

## Base commit - actual generated contract

# PR description contract
When this task opens or updates a PR, whether directly in direct-PR mode or through the no-mistakes pipeline, you own the quality of its description.
Include explicitly titled sections named "Summary", "What changed", "Why", and "How it was tested".
Make the Summary plain-language and understandable to a non-engineer.
Write for a reader who has not seen the diff, with no filler or restated commit lists.


## Target commit - actual generated contract

# PR description contract
When this task opens or updates a PR, whether directly in direct-PR mode or through the no-mistakes pipeline, you own the quality of its description.
Use a conventional-commit PR title with the repository's scope convention.
If `.github/PULL_REQUEST_TEMPLATE.md` exists, follow its section layout instead of the default below while keeping all brevity, content, voice, evidence, and rendering constraints in this contract.
Otherwise, use explicitly titled sections in this order: "Summary", "What changed", "Screenshots" (for UI changes), "How to review", "Testing", "Risk", and "Follow-ups".
Write the Summary as 3-4 plain-language sentences understandable to a non-engineer, explaining the problem and resulting behavior.
For UI changes, place Screenshots after What changed with the before and after evidence required below, including when following a repository template.
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


## Raw product evidence

- [Live CLI transcript](live-product-transcript.log)
- [Per-mode results](live-product-results.json)
- [No-mistakes delivered inbox record](promoted-no-mistakes-inbox.msg)
- [Direct-PR delivered inbox record](promoted-direct-pr-inbox.msg)
- [Local-only delivered inbox record](promoted-local-only-inbox.msg)
- [Persisted no-mistakes relaunch brief](promoted-no-mistakes-relaunch-brief.md)
- [Baseline regression result](baseline-regression.log)

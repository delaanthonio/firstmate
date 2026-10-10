# Pi rendering validation

Validated target `946e0026b69fbedc8b3a7bcdbce019c3198e370b` against base `cbad273fc16f39ed37c2a6425746085e10853e68`.

## Live product evidence

Real Pi CLIs ran in private tmux sessions with a 150 × 42 grid, separate FM_HOME and PI_CODING_AGENT_DIR directories, no operator credentials, and disposable saved-session input. Both extensions were loaded by Pi itself. Opening a saved conversation, Ctrl+O, /calm, /export, and /quit were driven through terminal input.

| Scenario | Observed result |
| --- | --- |
| Base extension on Pi 1.1.0 | Both tools omitted argument headers in collapsed and expanded views, reproducing the presentation defect. |
| Target extension on Pi 1.1.0 | Both tools showed recent=2 / through=1 collapsed, and recent: 2 / through: 1 expanded. |
| Target extension on Pi 0.87.1 | Both tools retained title-only headers in both views. |
| Calm toggle on both versions | Both tool rows disappeared; the genuine reply stayed visible; toggling off restored both rows. |
| Export with Calm active | Real /export retained both tools, arguments, results, and genuine conversation. |
| Synthetic input export boundary | Chrome computed visibility confirmed synthetic rows hidden in the conversation while preserved in the session tree; genuine operational user inputs remained visible. |

Terminal PNGs are browser-rendered copies of actual tmux viewport captures with terminal colors preserved. They are labeled accordingly. Export PNGs show Pi's actual generated HTML in isolated headless Chrome. The visibility JSONs were collected from the live rendered DOM using getComputedStyle and innerText; their instrumented copies add only a hidden observation report.

## Targeted checks

`bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh tests/fm-calm-pi-extension.test.sh --jobs 1 --json <evidence>/pi-new-timing-rerun.json` passed with Pi 1.1.0 and no skips. The branch comparison additionally uses Pi's real stock renderer; the Calm suite drives real Pi TUI sessions, restart, export, and Chrome rendering.

The initial local run failed because npm's default local layout hoisted dependencies the test fixtures expect nested inside Pi. Reinstalling into a disposable workspace with `--install-strategy=nested` resolved this setup failure; the unchanged checks then passed. An initial screenshot helper waited for Chrome to exit after it had already emitted an image; a bounded artifact-aware driver resolved that evidence-capture setup issue.

No static analysis, typecheck, complete repository suite, hosted CI job, push, PR edit, or merge was performed. Behavior portable serial 2 and 3 still require the outer executor's CI phase, without waivers, before the requested merge of #20. The attached plan's conflicting no-merge wording did not replace the authoritative user intent.

The disposable packages, sessions, profiles, data and helper scripts were removed from the worktree after validation. Scripts needed to reproduce the manual checks are retained beside this report.

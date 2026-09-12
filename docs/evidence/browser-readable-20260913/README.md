# Native readable Browser Lane observation

This isolated fixture run used server/TUI source `af3861a555e4e950c87b29724523a08adcc3aebe`
after PR #35533. Server SHA-256 is
`bde0ea63844eb9fb29c66f4f441a0f952723e1d3a1f6930d09d859bf6076e64d`;
TUI SHA-256 is `7b09669c233196b9152daa536d5a39f9fd067e8af79ae7b39268b5e263a5b051`.
The report retains observed build provenance and the selected runtime.

The retained trace has **6 outer calls, 0 errors, 3 compositions**, and **36,199
UTF-8 raw result bytes**. Elapsed observation was 40.207 seconds, including
request/status overhead. This is not provider wire input size or evidence of
causal performance superiority. Raw results are exact tool-use-ID joins;
producer result_bytes is checked separately when present.

The persistent native TUI replay contains 49 complete frames and all three
current URL/heading/message combinations. No input occurred after Keeper start.
TUI and Keeper observations have independent timing, not an atomic shared capture.
`tui-*.png` are xterm replays of captured native PTY bytes. `firefox-final.png`
is a separate actual Firefox screenshot. Scroll/navigation/follow PTY logs are
separate native fixture runs, not additional Keeper turns or this screenshot.

The browser-lanes instruction was copied from mutable worktree body
`d56dae645b` during setup. It is **not the same instruction** as the preceding
guided-content run. The exact received keeper_skill body remains in
raw-tool-results.json. browser-lanes.SKILL.md is the committed d56dae645b file
(13,391 bytes, SHA-256 6e3ea26f00a79eee164488476ecd4bcdb3e348fcd903a3bfe191e747e66576df).
The audit verifies its exact 13,159-byte delivered body against the first raw result
(body SHA-256 1a085c9cdf6752cf4193541ad2bbff3a9dd7ca06ef8c0a1c7a968238ef076b1c). This experiment does not isolate rendering from instruction
changes. No Slack session or token was used.

## Rechecking

Run `python3 audit.py` from any directory. It reads only sibling evidence files,
joins execution IDs and raw outputs, validates producer byte declarations,
checks captured lifetime metadata and all checksums. It does not independently
render terminal escape sequences. To rerender those, install the Python
Playwright package/browser and ttyd, then run `python3 replay-tui.py .` from this
evidence directory. That script starts a local terminal replay server, not MASC,
Keeper or the original website, and rewrites replay artifacts.

`historical-probe.py` is the original experiment driver retained for inspection.
It is not a portable replay command: its explicit scratch paths, dependency
helpers, runtime/provider configuration and credential-loading paths belonged to
the original operator environment. Do not run it as an offline audit. Actual
credentials, complete runtime configuration, unrelated history and trace events
are excluded. Report paths describe provenance, not required replay inputs.

The retained local audit and replay scripts allow evidence rechecking; they do
not reproduce a new authenticated Keeper experiment. No full installer, crash,
repeatability or guaranteed intermediate-page retention claim is made.

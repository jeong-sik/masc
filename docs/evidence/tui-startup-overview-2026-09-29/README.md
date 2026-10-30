# Working Overview from startup

Operator request: replace the oversized startup candle with the working
Overview. Keep `/about` and individual Keeper portraits.

- MASC Board: `p-7b748d3b035bcf15cb0807fce758dd0d`
- MASC Task: `task-1814`
- PR: https://github.com/jeong-sik/masc/pull/39798
- Issue: https://github.com/jeong-sik/masc/issues/39795

## Measured evidence

Producer head: `ce9a894e491f2e4c4476b04a2ac8fb88e315fa73`.
Run: https://github.com/jeong-sik/masc/actions/runs/36507301148
Artifact: `suite-runner-log`, artifact ID `11007688347`.
TUI SHA-256: `cc7956bf4c27541476828e594b85c8ceb316aae05270c92baf5362314853bf5e`.

Raw downloaded artifact: `ci-run-36507301148.log`.
Extracted terminal frames: `frames-ce9a894.json`; selected frames also have `.txt`
files (trailing cell padding trimmed in `.txt` only). These are actual Linux PTY
screen text, not native-terminal screenshots.
The escaped workspace URL is a synthetic terminal-injection test fixture.

- Startup and `/about` PTY: PASS (10 scenarios), 44 seconds.
- Keeper portrait PTY: PASS (3 scenarios), 13 seconds.
- `test_tui_emblem_screen`: PASS.
- `test_tui_emblem_state`: PASS.

The startup scenarios cover delayed read, first success, failure/retry,
immediate navigation, NO_COLOR, Kitty and narrow rendering. The narrow case
starts at 80x30 and resizes to 80x24 while loading. `/about` mosaic, NO_COLOR,
Kitty and modal key ownership remain covered.

## Integration follow-up

After this run, main added #39791's `/about` painted/dotted candle toggle.
The integration preserves that feature and its additional PTY scenario (now 11
emblem scenarios), while continuing to remove the startup mascot and state.
The evidence above proves only the named producer head. Integrated-head CI and
PR required checks are pending; no production installation or merge is claimed.

Reading these frames exposed retry prompts in unread Attention/Tasks sections
while the first request was pending. The integrated implementation now labels
those sections Loading/Waiting for workspace server; the PTY assertion also
rejects unquoted `press r`. The recorded frames predate that correction.

Static checks: OCaml parsing, Python AST parsing, variant consistency and
`git diff --check` passed. Source review found no correctness issue in the first
implementation. Local Dune builds were not run, per the execution protocol.

Task claiming remains blocked by the shared MCP caller's unrelated task. The
Board records this ownership limitation; completion has not been submitted.

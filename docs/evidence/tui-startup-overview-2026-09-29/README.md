# Working Overview from startup

Operator request: replace the oversized startup candle with MASC's working
Overview. Keep the candle on `/about` and individual Keeper portraits.

- MASC Board: `p-7b748d3b035bcf15cb0807fce758dd0d`
- MASC Task: `task-1814`
- GitHub issue: https://github.com/jeong-sik/masc/issues/39795

## Change

The existing compact Overview header and sections render from the first frame.
The summary distinguishes connecting, booting, an in-flight read and unavailable
data. Unread sections do not become zero counts. Startup mascot state and the
startup/about sizing variant are removed. `/about` keeps its fitting and motion.

## Verification recorded before CI

- OCaml parser checks on modified implementation/interface/test files: PASS.
  This is syntax validation, not a type check or build.
- Python AST parse of `test/test_tui_emblem_screen_pty.py`: PASS.
- `bash scripts/check-variants.sh`: PASS.
- `git diff --check`: PASS.
- Independent source review found no correctness defect. Stale comments fixed.
  This was a same-model source review, not runtime evidence.

## Runtime verification pending

The focused PTY suite exercises delayed first read, success, failed first read
and retry, immediate navigation, NO_COLOR, Kitty, and narrow rendering. The
narrow case starts at 80x30 and resizes to 80x24 while loading. Existing `/about`
mosaic, NO_COLOR, Kitty and key-ownership scenarios remain.

Each startup scenario emits terminal frame JSON and the executable SHA-256 into
the CI log. These are evidence producers, not results until the suite runs.
Keeper portrait preservation is also covered by its existing focused PTY suite.

No local Dune build or production binary replacement was performed. Changed-head
CI, actual terminal frames and screenshots remain pending. The task is not
submitted as complete: the shared MCP caller's unrelated task prevents claiming
it, and the Board records this ownership limitation.

# TUI Planning screenshots — 2026-08-22

These screenshots come from the actual `masc_tui.exe` built at
`d60227634b87f18b63b098c7a52b5ebdd9a8373d` for PR #29443. A local fixture
HTTP server supplied deterministic Planning snapshots; the TUI itself ran in a
real PTY through ttyd and rendered in Chromium.

- Captured: `2026-08-22T02:26:45Z`–`2026-08-22T02:30:18Z`
- PR / issue: `#29443` / `#29424`
- Code source SHA: `d60227634b87f18b63b098c7a52b5ebdd9a8373d`
- Evidence asset commit SHA: `63a61edd4466bd2559ae55adb94e0c2a7fe68b91`
- Worktree before capture: clean
- Executable: `_build/default/bin/masc_tui.exe`, `39,373,840` bytes,
  SHA-256 `87b86d9e72e1361284afc7ef639205c01d9d70af7f0e2eba660d63fcd2f73647`
- Build: `scripts/dune-local.sh build bin/masc_tui.exe
  @test/runtest-test_tui_planning_selection
  @test/runtest-test_tui_keyboard_input @test/runtest-test_tui_http_ast`
- Terminal: `99 columns × 30 rows`
- Screenshot: `834 × 480` pixels, device scale factor `1`
- Renderer: ttyd `1.7.7-unknown` DOM renderer, Playwright `1.59.0`, Chromium
  `147.0.7727.15`; ttyd does not report its bundled xterm.js version separately
- Runtime settings: `TERM=xterm-256color`, `MASC_TUI_SYNC=off`, refresh `60s`
- Screenshot selector: `.xterm-screen`
- Fixture source: `planning_selection_http_fixtures` and `planning_snapshot` in
  `test/test_tui_keyboard_input.py`, serving `/api/v1/dashboard/planning`
- Initial goals: `goal-a-29424 / plan-alpha-29424`, `goal-b-29424 /
  plan-beta-29424`, `goal-c-29424 / plan-charlie-29424`
- Replacement goals: prepend `goal-new-29424 /
  plan-new-reorder-applied-29424`, or replace Beta with `goal-d-29424 /
  plan-delta-missing-applied-29424`
- Post-capture changes: no DOM text replacement, redaction, AI generation, or
  image editing; all names and IDs are synthetic fixtures
- Machine-readable hashes and inputs: [evidence.json](evidence.json)

## Captures

| # | Observed behavior | Input and data change | Screenshot |
|---:|---|---|---|
| 1 | The selected Beta goal stays selected after a new goal is prepended. | `Tab` ×4 (`0x09`), `j` (`0x6a`); replace `[A,B,C]` with `[NEW,A,B,C]`; `r` (`0x72`) | [PNG](01-planning-selection-after-reorder.png) |
| 2 | Removing the open Beta detail returns to list mode with Charlie selected. | `Tab` ×4, `j`, `Enter` (`0x0d`); replace `[A,B,C]` with `[A,C,D]`; `r` | [PNG](02-planning-list-after-detail-removal.png) |
| 3 | One `j` after recovery selects Delta, and `Enter` opens Delta's detail. | Independent replay: `Tab` ×4, `j`, `Enter`; replace `[A,B,C]` with `[A,C,D]`; `r`, `j` (`0x6a`), `Enter` (`0x0d`) | [PNG](03-planning-detail-after-recovery-navigation.png) |

The screenshots prove the fixture-backed terminal rendering. The PTY regression
tests remain the behavior proof. Neither claims that this PR is deployed or that
a production API served the snapshots.

[근거] The exact executable SHA-256, terminal dimensions, browser terminal
buffer assertions, PNG dimensions, and PNG SHA-256 values were read during the
capture on 2026-08-22 KST; confidence High.

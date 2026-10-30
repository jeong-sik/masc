# TUI Keeper selection screenshots — 2026-08-22

These screenshots come from the actual `masc_tui.exe` built at
`a451478677bbbce1f7b3fc8bcea50d5af1af18cf` for PR #29476. Each image used an
independent temporary workspace and local fixture HTTP server. The TUI itself
ran in a real PTY through ttyd and rendered in Chromium.

- Captured: `2026-08-22T03:28:45Z`–`2026-08-22T03:28:54Z`
- PR / issue: `#29476` / `#29453`
- Code source SHA: `a451478677bbbce1f7b3fc8bcea50d5af1af18cf`
- Evidence asset commit SHA: `80f09eec2ae27ed1f73332e8d39512be53848bdb`
- Worktree before capture: clean
- Executable: `_build/default/bin/masc_tui.exe`, `39,392,160` bytes,
  SHA-256 `db03557c032799d51dbdfa2766123fa6adc898d5ad7d0c7b429a7e428bcd5074`
- Build: `scripts/dune-local.sh build bin/masc_tui.exe
  @test/runtest-test_tui_keeper_selection
  @test/runtest-test_tui_keyboard_input @test/runtest-test_tui_http_ast`
- Terminal: `99 columns × 30 rows`
- Screenshot: `834 × 480` pixels, device scale factor `1`
- Browser viewport: `860 × 496` pixels
- Renderer: ttyd `1.7.7-unknown` DOM renderer, Playwright `1.59.0`, Chromium
  `147.0.7727.15`; ttyd does not report its bundled xterm.js version separately
- Terminal font: Menlo, `14px`
- Runtime settings: `TERM=xterm-256color`, `MASC_TUI_SYNC=off`; refresh `60s`
  for detail removal and `0.05s` for both Message captures
- Screenshot selector: `.xterm-screen`
- Fixture source: `seed_workspace`, `keeper_metadata`, and
  `overview_event_http_fixtures` in `test/test_tui_keyboard_input.py`
- Post-capture changes: no DOM text replacement, redaction, AI generation, or
  image editing; all names and IDs are synthetic fixtures
- Machine-readable hashes and inputs: [evidence.json](evidence.json)

## Captures

| # | Observed behavior | Input and data change | Screenshot |
|---:|---|---|---|
| 1 | Removing the open Beta detail returns to the one-row Keeper list; it does not open Alpha detail. | `2`, `j`, `Enter`; update Alpha generation to `29454`, remove `beta.json`; `r` | [PNG](01-keeper-list-after-detail-removal.png) |
| 2 | Removing the Beta message target keeps `Message to: beta` and its draft while disabling Enter. | `2`, `j`, `Enter`, `m`, type `beta-periodic-draft-29453`; remove `beta.json`; periodic refresh | [PNG](02-message-after-target-removal.png) |
| 3 | An unrelated malformed Alpha record makes the roster unreliable without losing the Beta target or draft; new sends are disabled. | `2`, `j`, `Enter`, `m`, type `beta-unreliable-draft-29453`; replace `alpha.json` with malformed JSON; periodic refresh | [PNG](03-message-after-roster-read-error.png) |

After captures 2 and 3, Enter followed by `x` was sent through the same browser
terminal. The existing draft gained `x`, and the fixture server observed zero
POSTs to `/api/v1/keepers/chat/stream` in both executions.

The screenshots prove the fixture-backed terminal rendering. The pure
reconciliation tests and PTY regression suite remain the behavior proof.
Neither claims that this PR is deployed or that a production API served the
snapshots.

[근거] The exact executable SHA-256, terminal dimensions, browser terminal
buffer assertions, disabled-send POST counts, PNG dimensions, and PNG SHA-256
values were read during the capture on 2026-08-22 KST; confidence High.

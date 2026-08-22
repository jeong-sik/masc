# TUI Operator approval screenshots — 2026-08-22

These screenshots come from the actual `masc_tui.exe` built at
`897b58aaf07745d4515f5e87c23872d25c129553` for PR #29466. Each image used an
independent temporary workspace and local fixture HTTP server. The TUI itself
ran in a real PTY through ttyd and rendered in Chromium.

- Captured: `2026-08-22T04:14:02Z`–`2026-08-22T04:14:08Z`
- PR / related issue: `#29466` / `#29418`
- Code source SHA: `897b58aaf07745d4515f5e87c23872d25c129553`
- Evidence asset commit SHA: `5fb44971fb93edc92fd77f5973012442e90a28a0`
- Worktree before capture: clean
- Executable: `_build/default/bin/masc_tui.exe`, `26,191,616` bytes,
  SHA-256 `eff98be54d03da842466c14f6cc55ed74695bf32cee17b36f55670fb992aa6a1`
- Build: `scripts/dune-local.sh build bin/masc_tui.exe
  @test/runtest-test_tui_decode @test/runtest-test_tui_operator_projection
  @test/runtest-test_tui_http_ast @test/runtest-test_operator_control_actions`
- Focused results: decode `28/28`, operator projection `8/8`, HTTP AST `10/10`,
  operator actions `8/8`
- Terminal: `99 columns × 30 rows`
- Screenshot: `834 × 480` pixels, device scale factor `1`
- Browser viewport: `860 × 496` pixels
- Renderer: ttyd `1.7.7-unknown` DOM renderer, Playwright `1.59.0`, Chromium
  `147.0.7727.15`; ttyd does not report its bundled xterm.js version separately
- Terminal font: Menlo, `14px`
- Runtime settings: `TERM=xterm-256color`, `MASC_TUI_SYNC=off`, refresh `60s`
- Screenshot selector: `.xterm-screen`
- Fixture contract source: `approval_item_json` and `snapshot_json` in
  `test/test_tui_operator_projection.ml`; the capture served equivalent inline
  responses from a local HTTP server
- Post-capture changes: no DOM text replacement, redaction, AI generation, or
  image editing; all names, tokens, and IDs are synthetic fixtures
- Machine-readable hashes and inputs: [evidence.json](evidence.json)

## Captures

| # | Observed behavior | Input and data change | Screenshot |
|---:|---|---|---|
| 1 | After a new approval is prepended, the selected `token-b` row remains `keeper_probe / beta`; the first `y` arms that exact action and sends no POST. | `Tab`, `Tab`, `j`; replace `[A,B,C]` with `[NEW,A,B,C]`; `r`, `y` | [PNG](01-approval-selection-after-prepend.png) |
| 2 | A U+009B payload is displayed as inert `\u009B31mOWNED-29466` text instead of a terminal control. | `Tab`, `Tab`; serve one approval whose reason begins with U+009B | [PNG](02-approval-payload-c1-sanitized.png) |

The first browser-terminal execution observed zero POSTs to
`/api/v1/operator/confirm`. The second inspected the xterm DOM buffer: the raw
U+009B code point was absent and the literal escaped evidence was present.

The screenshots prove the fixture-backed terminal rendering. The pure
projection, AST wiring, and operator action suites remain the behavior proof.
Neither claims that this PR is deployed or that a production API served the
snapshots.

[근거] The exact executable SHA-256, terminal dimensions, browser terminal
buffer assertions, POST count, PNG dimensions, and PNG SHA-256 values were read
during the capture on 2026-08-22 KST; confidence High.

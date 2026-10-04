# Lane removal effects and current TUI commands

U1/U2 from #41100; stacked above #41121 (`02b1450be6f106198f9e156d8ffcb2fb7e8796f5`).

Web distinguishes Remove TOML + worker from Remove worker and names the disk deletion next to the action. The TUI row controls/help name the same effect. Guides now describe A → command → Enter, global colon navigation, list Enter and detail-only Tab. Runtime ownership/deletion handlers and confirmation behavior are unchanged.

26/26 existing Dashboard component tests passed after the clean rebase onto the package-readings change. OCaml 5.5.1 parser checks passed for the two affected OCaml files. No native TUI or PTY ran. A real Chromium fixture renders the actual panel with synthetic managed/manual instances: both labels and effect explanations are visible, and no mutation was sent. Five assertions passed; screenshot inspected. A root review response bounded the Actions explanation width after the first screenshot made the other columns unnecessarily narrow. The final screenshot uses that correction.

Source hashes: checks.json. Browser fixture/result/log/screenshot are adjacent. It uses the prior package-readings fixture entry point only to mount the same real component/styles. No real TOML deletion, Docker cleanup, backend, CI, merge or deployment was exercised. Source review is separate from GitHub approval.

Independent review found three stale expectations in test_tui_lane_visual_pty.py (failed-worker removal label, advanced-command help and literal-colon prompt). All now follow the new displayed controls/prompt; Python AST passed. PTY remains unrun. The initial source pass missed these direct consumers and was superseded by this correction.

## Current parent integration checks

Integrated parent `1110d7d150410e189b9bcf468cdeb686fe9f965a` cleanly. The native
renderer, native test and visual PTY source retain the original child bytes;
parent Web unsafe-integer coverage is preserved. The earlier browser screenshots
and manifests remain historical evidence, not new browser execution.

The focused TUI and Lane test build passed. Actual fixture PTY `main` and
`run_navigation_consistency` both passed, exercising removal labels, help,
resizing and advanced command input. Binary SHA-256:
`9b7a93af23d70eaec2585e2f7dfad23b1d59b497ded7f92b844b6a1ca22e784e`.
Dashboard component tests: 27/27 passed; TypeScript, scoped ESLint, Ruff and
Pyright passed.

The full focused Lane native executable passed **16/17**. Its inherited
`declared layers use exact configured owners` assertion expects `1 result row`,
while the unchanged parent `flow_worker_state` emits `1 record`. Both source
blocks are identical to the parent; the parent executable was not rerun.
Tracked as [#41174](https://github.com/jeong-sik/masc/issues/41174), with the
assertion preserved. This is not a full native-suite pass. No real deletion,
worker cleanup, production endpoint or deployment was exercised.

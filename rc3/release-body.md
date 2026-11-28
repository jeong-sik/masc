## [0.82.0] - 2026-11-24

### Added

- Extend the unified Left Navigation Sidebar (`[b]` / `Ctrl+B` / `Alt+B`, auto-docked at `>= 132` cols and floating drawer `< 132` cols) with Wave 2 tabs and persistent top-chrome utility badges (`[I]`, `[^T]`, `[,]`, `[?]`), promote `Work > Schedules`, `Runtime > Fusion`, `Runtime > Tools & Usage`, and `Runtime > Connectors` to 1st-class `Nav` tabs, synchronize `Keepers` split/dive sub-tabs, and add a 100% keyboard reachability matrix test (#54483).
- Add Per-Turn Keeper Context Inspector (`Composition` occupancy/sparkline/history-reach/stacked-bar + Next-Request Forecast Band, `Exact_input` wire parts + lazy reader + Cache Outcome diagnosis, `Input_map` proof table, and `Response` transcript + tool execution evidence) in `4 Keepers > Context & Turns`, `Dive_keeper`, and `Ctrl+T` Context drawer (#54483).
- Add `5 Runtime > Tools & Usage` 3-subview analytics (`24h`/`7d`/`14d` Braille curves & failure classes, `Catalog Tree` with `Tool_dive` per-tool series, `Keeper Surface & Skills`), dedicated 2-pane `5 Runtime > Connectors` (`[n]` bind, `[U]` unbind), and `4 Keepers > Tool Calls` with scrollable unfolded JSON detail (#54483).
- Add pure `Html_doc` DOM renderer (stripping `<script>`/`<style>`/`hidden`, grapheme-safe CJK/ASCII wrapping, aligned tables, lists, code blocks, search highlight) with `[v]` Doc/Raw toggle, `{`/`}` revision stepping, `/` in-doc search (`n`/`N`), `[c]` verification checks, `[P]` CAS share toggle with HTTP 409 conflict auto-refresh, and `[Y]` share URL copy (#54483).
- Add live `GET /api/v1/board/hearths` picker (`[h]`), threaded board comments (`order_comments_threaded`), `[c]` post/comment composer modal, and two-press armed `+`/`-` voting on `3 Knowledge > Board` (#54483).
- Full `Fusion` detail surface (`Fusion_dive`), launch config presets (`/runtime/config/fusion`), and linked board evidence (`/board/:post_id`) with retained-vs-historical routing and stale `run_id` guards (#54486).
- First-class `Work > Harness` health & overrule workflow (`/dashboard/harness-health`), `Verification_dive` evidence viewer (`/verification/{evidence,summary,specs,tlc-results}`), `Infra > Activity & Logs` cold-open backfill (`/activity/events`), `[a]` Acting rail & runtime-trace dive, and remote-safe `Keepers > Logs` (`Nav.Keeper_logs`) (#54486).
- First-class `Infra > Code` (`Nav.Infra_code`) workspace tree, fuzzy file finder, ripgrep search, syntax-highlighted reader (`Masc_tui_ui.Code_lexer`), and `[g]` Git status/branches/worktrees/blame/log/diff views (#54486).
- `Memory` health, workspace ledger/context, collapsible Facts Tree, and activity journal sub-views inside `Knowledge > Memory` and `Keeper_dive > Memory` (#54486).
- `Keepers > Identity` (`Nav.Keeper_identity`) OAuth & GitHub device-flow / masked-PAT workflows, `Runtime > Addons` `[p]` Package Catalog browser, and `Runtime > Connectors` `/connector/names` bind picker (#54486).
- The TUI Keepers list shows each keeper's next due schedule, and a keeper's work tab shows the last 6 and 24 hours of turns by what started them (scheduled, reacted, chat, own, unknown) with the next due time beside each schedule (#54507).
- The dashboard keeper detail shows the last 6 and 24 hours of turns, turns per hour, and what started them (scheduled, reacted, chat, own, unknown). The execution snapshot's keeper rows now carry the same `recent_turns` pulse the gate roster sends (#54519).
- Add a collapsible Left Navigation Sidebar (auto-docked on wide terminals, floating drawer on narrower terminals) with `[b]`/`Alt+B` toggle, focus SSOT selectors, and section-level workspace shortcut labels (#54526).
- Unify TUI navigation with a `Tab`/`Shift+Tab` focus ring across the Left Sidebar and Body panes, live screen preview on sidebar arrow movement, and mouse click/wheel navigation (#54527).
- Add TUI artifact HTML/Markdown preview, raw-body clipboard copy (`[y]`), SHA-256 copy (`[H]`), atomic local `.html`/`.md` export (`[e]`), and validated local export opening (`[o]`) across `3 Knowledge > Artifacts`, `Artifact_dive`, and `Media_viewer` (#54538).
- Add dedicated `5 Runtime > Addons & Browser` sub-tab showing live/retained addon lanes alongside browser lane clients, inventory issue rails, and on-demand per-tab listings (`[t]` refresh, `[Space]` Clients/Tabs focus, `[y]`/`[o]` actions) with observer invalidation for `lane_addon*` and `browser_observation` events (#54538).
- Add pure real-revision `Memory_flow` Braille time-series charts (`Flow_io` dual-inverted and `[g]`-toggled `Net_total`) to `3 Knowledge > Memory`, `Memory_diff_dive`, and `Keeper_dive > Memory` (#54538).
- Add honest per-view SSOT freshness indicators (`● LIVE SSE`, `◐ SYNCED`, `○ SNAPSHOT`) in the TUI top bar, footer, and mixed-mode panes, and unify `6 Infra > Activity & Logs` with `[s]` cycling `ALL`/`LOGS`/`EVENTS` (#54538).
- Display running TUI and connected Server build versions and short commit hashes inside the `?` Help top bar (flagging commit mismatches) and `,` Settings header/subtitle (#54544).
- Public `GET /health` now advertises `auth_methods` (`google`, `github`, `dev_token`) in both single-user mode (keeping `account_mode` absent for `masc-tui` v2.6 compatibility) and multi-account mode (#54556).
- Multi-account servers (`Server_accounts`) now serve the unified dashboard SPA at `/dashboard` under a strict zero-inline-script CSP, redirect `/accounts/console` to `/dashboard#account`, bridge RBAC-gated operational dashboard APIs via `Auth_gate` with `Board_access.Workspace_member` privacy scoping, and expose a cookie-authenticated Observer SSE stream at `GET /api/v1/auth/events` with query-string token rejection (#54556).
- Multi-account Admin sessions can now disable, re-enable, revoke Admin (with strict closed-sum `cause`), and delete members via `POST /api/v1/auth/members/:id/{disable,enable,revoke-admin}` and `DELETE /api/v1/auth/members/:id` (#54556).
- TUI dedicated Ask Answer modal (`Nav.Ask_answer`) supporting single-select, multi-select (`Space`), multi-question navigation (`[`/`]` and `Tab`/`Shift+Tab`) with per-question draft isolation, UAX #29 grapheme-safe UTF-8 free-text (`i`), skip (`⊘`), clamped `J`/`K` prompt scrolling, live open/in-flight/closed guard, and honest HTTP ack/error draft preservation (#54559).
- TUI utility overlay number shortcuts `7` (Settings), `8` (Incidents), `9` (Queue/Context), and `0` (Help) in unfocused navigation and focused Left Sidebar without hijacking focused text inputs (#54559).

### Changed

- In the TUI composer, `Enter` queues behind a busy Keeper and `Alt+Enter` / `Ctrl+Enter` steer (#54481).
- A Keeper's turn pulse counts both lanes and what started each turn. Each half-hour slot counts turns by outcome (`ok`, `rested`, `failed`) and by cause (`scheduled`, `reacted`, `chat`, `own`, `unknown`), and the roster sends each slot as a named object instead of a positional array. A successful direct request counts as `chat`; a failed one writes no decision row and is not counted. A restart seeds the causes by joining each decision row to the turn log's `Opened` line on `trace_id#turn_id`, and a row with no such line counts as `unknown` (#54506).
- The TUI draws the focused pane with a heavy border and a `▸` before its title, and draws the title of an unfocused pane in the muted structure style. The footer starts with a pill that names what has the keys, for example `▸ 1/4 Attention`, `▸ COMPOSER @<keeper>` or `▸ FILTER` (#54510).
- No body pane draws as focused while an overlay, the filter or the Composer has the keys (#54510).
- The TUI footer shows up to 14 key hints on Standard and Wide terminals (7 before) and ranks `Tab`, `?`, `Ctrl+K`, `,`, `I` and `Ctrl+T` higher, so pane switching and the overlay keys show on an ordinary workspace. The footer leaves out `Y` and `N` while the approval strip above already shows them, `[` and `]` where there are no sub-tabs, and `Esc` at the top level. The help text for `Space` lists what it toggles in each view (#54511).
- The TUI dims the area between the top rail and the footer behind an open overlay, and the body and the approval strip behind the slash and mention popups, so text behind them no longer shows through their borders (#54511).
- Promote `Knowledge -> Wiki` and `Knowledge -> Artifacts` to separate first-class sub-tabs (removing the hidden `Space` toggle), rename `Work -> Pipeline` to `Goals`, and index all 21 reachable TUI screens in the `Ctrl+K` Palette (#54525).
- Recent Actions in the Keeper prompt now states one attribution per run of successful calls that share it, instead of one per call. A row lists the tools in the order called with `×N` after a tool that ran N times in a row; refused, deferred and unrecorded calls keep their own rows and no call is dropped (#54539).
- Append the embedded 8-character Git commit SHA to `masc-tui --version` (e.g. `0.81.0 (2a58dc57)`, falling back to bare SemVer when unembedded) while keeping `--build-commit` (full 40-char SHA) and `masc --version` (bare SemVer) unchanged (#54544).
- TUI keymap consistency: `←`/`→` strictly perform spatial pane and Left Sidebar movement (never cycling sub-tabs), `[`/`]` strictly switch sub-tabs, and `Space` (`Toggle_expand`) is strictly safe and local-only with zero network POSTs (Settings and Keeper Config dry-run diff moved to `d`; Keeper Identity OAuth toggle moved to `a`/`Enter`) (#54559).
- TUI Ask triage surfaces: `Approval_strip` and `Pulse` display honest Ask action labels, `Y`/`Alt+Y` and Inbox/Pulse `Enter` open the Ask Answer modal instead of blindly submitting choice #1, `N`/`Alt+N` skips all questions in an Ask, `J` teleports to `Work > Inbox` and opens the modal, `C` jumps to Keeper Chat, and `Work > Inbox` removes hardcoded fake choice-1 selection and unbound choice hotkeys (#54559).

### Removed

- The TUI harness overrule key and form, which could never send the verdict hash the route requires (#54477).
- The TUI `S` (Speak) key, which called the TTS setup probe, spent a credit per press and played no audio (#54480).
- The TUI Board quarantine list, its `R` / `Y` requeue and the Pulse quarantine count. The list was never fetched, its decoder and requeue body did not match the server, and the count always read 0 (#54501).

### Also in this release

- Fixed: 61 entries
- Internal: 1 entry

Every entry is in [CHANGELOG.md](https://github.com/jeong-sik/masc/blob/v0.82.0/CHANGELOG.md) under `## [0.82.0] - 2026-11-24`.

**Full changelog**: https://github.com/jeong-sik/masc/compare/v0.81.0...v0.82.0

**Verified candidate**: https://github.com/jeong-sik/masc/actions/runs/45371767983

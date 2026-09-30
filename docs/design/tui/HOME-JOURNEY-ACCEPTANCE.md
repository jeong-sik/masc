# Home journey acceptance

2026-09-30. Integration PR #40176, source head
`e19835974415bf7f4143c8ead5f82fc51f93081e`, stacks on #40152 (individual
requests), #40137 (conversation receipts), #40130 (layout) and the original
#39817. It also integrates #40120 and its #40116 complete-draft dependency.
This checklist records remaining acceptance work, not a runtime or merge verdict.

The combined source covers Home request identities and partial readings, saved
explicit conversations independent of startup, complete per-Keeper drafts, and
creation recovery through a confirmed named composer returning Home. Current-head
execution and visual evidence remain required for that combined behavior.

| Required behavior | Current source or test | Evidence still required |
|---|---|---|
| Concise Home with decisions, continuation and recipient selection | `render_overview`, `home_decision_rows`, `home_continue_rows` | Current-head rendered frames and visual inspection |
| Unknown or failed reads never imply zero decisions | `approvals_reading_current`; `unknown_and_resume` | Current-head PTY pass; partial-source failure and connection-failure cases |
| Automatic Gate work is distinct from human decisions | `approval_item_needs_person`; mixed Gate scenario | Current-head PTY pass and Home/strip comparison |
| Keeper zero preserves existing Goal confirmations | `empty_roster_preserves_confirmation` | Current-head PTY pass |
| Empty workspace leads to creation | `Home_create_keeper` dispatch | Creation success/failure journey with inputs preserved |
| Enter opens requests without deciding them | `requests_are_navigation`, `assert_no_decision_posts` | Current-head pass; individual request identity and duplicate cases |
| A newly inserted destination does not steal selection | `refresh_preserves_destination` | Current-head PTY pass |
| Removed selection requires reselection | `home_selected_action`; refresh scenario | Current-head pass; deleted Keeper resume case |
| Fixed startup Keeper is not a last-chat receipt | `remember_home_chat`; `opening_boot_frames` | Current-head Overview PTY pass |
| Home chat returns with draft intact | `Keeper_chat_return_home`; `unknown_and_resume` | Combined-head `background_ask_keeps_beta_draft` text/media/no-autosend evidence |
| Text, attachments and references stay bound to their recipient | `message_draft`, complete save/restore in `open_message_for_keeper` | Combined-head `test_tui_keeper_draft_payload_pty` A→B→A wire results |
| Creation failures retain input and malformed JSON is recoverable | `keeper_creation_draft`, guarded JSON/name parsing and receipt validation | Combined-head malformed/refused/success retries from Home and Keeper list |
| Created Keeper is selected for the first assignment | Named chat handoff with no-op queue drainer and typed Home return | Combined-head explicit first-assignment wire target, response and Home return |
| Remembered target remains visible during roster failure | `Home_read_last`, existing unavailable-recipient send authority | Combined-head roster failure history, no POST, complete deletion re-selection |
| Short-height Home reserves continuation and new work | Budgeted request window with retained continuation and short fallback | Combined-head 17-row Home and 24-row composer acceptance |
| Wider Home does not add default panels | CI replay frames 03, 06, 09, 12 show the automatic Recent pane at 160 columns | Suppress automatic extra Home panels while preserving explicit operator choices |
| Overview startup remembers a last conversation across restarts | Typed receipt and `[tui].last_chat_keeper` Runtime locked writes | Combined-head same-workspace restart in Overview/Keeper/Last, save/read failures and deletion |
| All sources retain their distinct decision identity | `home_request`, `home_decision_rows`, `reconcile_home_request_detail` | Current-head individual request, duplicate, same-Keeper distinct calls, partial-source failure and detail-refresh PTY results |
| Acceptance sizes and color-independent actions | `test_tui_home_viewports_pty.py`: 80×24, 120×32, 160×48, normal and NO_COLOR | Targeted run 36654334047 passed at `45c065b875`; raw CI frame replay and screenshots are recorded below |
| Large queues preserve continuation and reach every request | Retained `home_decision_scroll` and request viewport in `render_overview` | Overflow journey at acceptance sizes and detail return with selection/window retained |
| Accepted decisions distinguish receipt from application | Typed outcomes, dispatch-bound Home receipt, `test_tui_home_decision_receipt_pty` | Combined-head deferred receipt and fresh pending/removed source observations |
| Usage entry is independent of prior Telemetry visit | Existing Usage keyboard scenario | Current-head targeted suite and rendered Usage evidence |
| Improved time to first action | No user timing measurement here | Same-task before/after operator observation; do not infer speed from layout |

The viewport suite deliberately captures fresh full redraws after actual size
changes. It checks final terminal row addresses, fixture cell widths and NO_COLOR
color escapes as well as text, emits raw base64 PTY
frames as `HOME_JOURNEY_FRAME`, and rejects product POSTs during navigation.
Enter dispatch is exercised at each size. Visual inspection remains required;
these checks do not emulate every terminal's display rules.
These are synthetic fixture observations when executed. They cannot prove
Keeper operation, production readiness, installation, or human action timing.

Run the focused acceptance in CI with:

```sh
gh workflow run test.yml --ref <branch> -f suite=test_tui_home_viewports_pty
```

No local Dune build is needed. Current-head required PR checks, focused test
results, binary provenance, fixture screenshots and production observations
must remain separate evidence. A passing viewport suite closes only its row.

## Current viewport evidence

[CI fixture frame evidence](../../evidence/tui-home-journey-20260930/README.md)
records twelve raw frames and their Chromium/xterm replay screenshots from
source/test head `45c065b875c550e7109e59d86d3d2c31de9422da`. This includes the
reviewed Home source above with the viewport assertions added. The passing
targeted run establishes the two fixture states at the three specified sizes
in normal and NO_COLOR modes. The remaining checklist rows stay open.

Run 36664548724 at `5924e6846516bb9bc97bbdf96b5a2abdd3a39294` passed
Home layout (2 scenarios) and viewport (4 scenarios, 12 frames), but the overall
run failed in request-label/detail assertions and unchanged-title redraw waits.
Those observations are limited to that pre-integration head. Current integration
run 36667431835 targets the seven Home/creation/draft suites; its result must be
read against its exact head before any acceptance claim.

Remaining deliverables include Task-card detail acceptance, connection-loss and
draft-during-notification cases, accepted-but-not-applied decisions, current-head
screenshots, required merge checks and freshness, installation/runtime inspection,
and same-task before/after operator timing. No timing improvement is claimed.

# Home journey acceptance

2026-09-30. Implementation under review: PR #39817, source head
`6ac4da4e23d3a1a66422c76e89ebad102dbcf5f3`. Parent #38801 merged on
2026-09-29. This checklist records remaining acceptance work; it is not a
runtime-success or merge verdict.

The decision-card stack on #40137 replaces aggregate-only Home navigation with
kind-and-request-ID rows, preserves successful sources during another source's
failure, and windows requests while retaining continuation. Exact readers retain
a Home return origin and request identity across asynchronous refresh. These are
source changes under validation, not rendered or runtime acceptance evidence.
The independent creation and complete-draft PRs still require whole-feature
integration. Receipt restart fixtures now run both binaries through the same
terminal-owning shell; their latest execution remains pending.

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
| Home chat returns with draft intact | `Keeper_chat_return_home`; `unknown_and_resume` | Current-head PTY pass; draft during incoming notification |
| Text, attachments and references stay bound to their recipient | `save_message_draft` currently saves only text | Preserve complete per-Keeper drafts and verify A→B→A wire payloads |
| Creation failures retain input and malformed JSON is recoverable | Creation handler parses without an exception branch and restarts from a stem | Guard parsing, retain declarations, verify malformed/failed/success retry |
| Created Keeper is selected for the first assignment | Creation currently reports success only | Refresh roster and hand off to the named composer |
| Remembered target remains visible during roster failure | Resume currently requires a successful roster read | Last-record presentation with unavailable status and safe send authority |
| Short-height Home reserves continuation and new work | Renderer currently ignores its body budget | Height-aware layout and short-height PTY acceptance |
| Wider Home does not add default panels | CI replay frames 03, 06, 09, 12 show the automatic Recent pane at 160 columns | Suppress automatic extra Home panels while preserving explicit operator choices |
| Overview startup remembers a last conversation across restarts | `home_last_chat` is session-only | Independent durable navigation receipt and restart/deletion verification |
| All sources retain their distinct decision identity | `home_request`, `home_decision_rows`, `reconcile_home_request_detail` | Current-head individual request, duplicate, same-Keeper distinct calls, partial-source failure and detail-refresh PTY results |
| Acceptance sizes and color-independent actions | `test_tui_home_viewports_pty.py`: 80×24, 120×32, 160×48, normal and NO_COLOR | Targeted run 36654334047 passed at `45c065b875`; raw CI frame replay and screenshots are recorded below |
| Large queues preserve continuation and reach every request | Retained `home_decision_scroll` and request viewport in `render_overview` | Overflow journey at acceptance sizes and detail return with selection/window retained |
| Accepted decisions distinguish receipt from application | Existing detail actions | Accepted-but-not-applied fixture and fresh-read verification |
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

After preparing an approved candidate and its selection receipt with the
[leader-selected CI procedure](../../CI-REVIEW-WORKFLOW.md), request the focused
acceptance on that exact candidate:

```sh
gh workflow run leader-ci.yml --ref main \
  -f candidate=<candidate-sha> -F selection=@selection.json \
  -F tests=true -f suites=test_tui_home_viewports_pty
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

Follow-up implementations submitted for review: #40116 binds full drafts to
their Keeper; #40120 preserves creation declarations and opens the confirmed
target for explicit first assignment. Their scoped runtime results and Home
integration are still required; submission is not completion evidence.

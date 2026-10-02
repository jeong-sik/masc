# Home journey acceptance

2026-09-30. Integration PR #40176 targets main. The Home product source head
is `f8f46d5f4005c1832b06fa5036aad1674fe26ef9` after the declaration-only
creation collision fix #40292, incorporating main
`0c37b5c28586cb812799c872aad99fffe67ee809`. Validation follow-up #40284
is stacked directly on #40176; this documentation follow-up is above #40284.
The integrated source includes #39817/#40113/#40130/#40137/#40152 and
creation/drafts #40120/#40116. Previous-head run 36698729943 at
`2f507d79d65946d168d118f0bf07893738a65b6b` was cancelled:
TLA and Dashboard typechecking succeeded, Dune and lint did not complete, and
the aggregate required-success job failed. This is not build success.
No new-head CI was requested. This checklist records acceptance work, not a runtime or merge verdict.

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
| Wider Home does not add default panels | Default/Chosen pane state; layout fixture and historical 5924 frames omit automatic Recent | Current-head visual proof and explicit choice/resize PTY pass |
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

## Verification policy

Follow `docs/AGENTIC-WORKFLOW.md`: feature and CI improvement stacks stay
separate. Only the bottom of a stack receives a minimal Core build; upper PRs
receive source review. No automatic CI or repeated long dispatches are requested.
Full integration and runtime verification belong to the Release/Tag candidate.
Test and native probe workflows were manually disabled, and the operator chose
to preserve that setting. Their absence is not a passing executable result.

At the release boundary, bind every executed fixture and screenshot to the
candidate binary SHA, harness SHA and artifact checksums. Keep source approval,
Core build, Full CI, fixture behavior, installed/runtime observations and human
timing separate. A passing viewport suite closes only its own row.

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
Those observations are limited to that pre-integration head. Later runs and their results must be read against their exact head before any
acceptance claim. The current cancelled run is recorded at the top.

Remaining deliverables include Task-card detail acceptance, connection-loss and
draft-during-notification cases, accepted-but-not-applied decisions, current-head
screenshots, release candidate execution evidence, installation/runtime inspection,
and same-task before/after operator timing. No timing improvement is claimed.

Full HTTP loss and local Task detail/deletion now have a dedicated fixture suite,
`test_tui_home_failure_task_pty`. It includes an attempted Enter send with retained
draft and no chat-delivery POST. Source guards preserve waiting inputs and queues
before dequeue and block Goal/Task changes while workspace identity is unread or
mismatched; confirmation bindings are cleared. These additions await executable CI.
Run 36668937812 at cc4da7d7a2f89ce493d06128168692f9c5896e20 passed
decision receipts (2), creation (4), and complete drafts (2), but failed card
detail assertions and deletion refresh observation. It does not establish current-head acceptance.

## Delivery evidence still open

Source approval and scoped merge readiness follow the current execution protocol;
they do not establish whole Home acceptance. Current candidate execution and
the relevant whole-journey results remain unproven.
The Usage family `test_tui_keyboard_input-dashboard-usage` must be included in
final verification; passing Home navigation alone does not prove its independent
Telemetry/Usage behavior. A CI probe artifact must identify its source SHA and
checksums before installed or runtime observations can be attributed to this change.
No historical screenshot or HTML prototype establishes current candidate behavior.

Human timing requires an operator performing the same first-assignment, resume,
and decision tasks before and after the change. Record the binary SHA, workspace
state, key count, elapsed time, and outcome for each observation. Automated fixture
key counts can describe a route but cannot replace this measurement.

The 5924 historical replay has been recaptured with corrected terminal padding
and measured CSS bounds. All twelve raw PTY/text records are unchanged; the last
composer row is fully visible. This closes the replay clipping defect, not
current-head visual acceptance. Local queue identity recovery now has a separate
fixture suite, `test_tui_home_queue_identity_pty`, covering unread settlement,
rejected `/steer` and `/run-next`, and explicit recovery with the saved request ID.
Its executable result remains pending.

Installed baseline identity and three isolated fixture frames are retained in
[baseline evidence](../../evidence/tui-home-installed-baseline-20260930/README.md).
The installed macOS arm64 binary is 0.49.0 at c112b203, before integration.
It is not a current-head runtime proof. A native manual probe is being prepared
for candidate verification without local builds or replacing active sessions.

The card detail fixture now uses visible call identity and command content in
all refresh/window cases; private `call=`/`args=` trace strings are not display
contracts. A dedicated overflow suite covers 64 distinct requests at each
acceptance size; its runtime and duration remain unproven until targeted CI.

## Inline review response after ba0a831

Transient Ask read failures retain the Home-opened reader and partial answers;
only a successful matching-workspace read may clear the removed Ask. Workspace
identity is applied before HTTP snapshots, and explicit decision dispatches
refuse unread/mismatched identity. New fixture suites cover foreign-workspace
decision refusal and question draft recovery. Matching identity/roster recovery
pumps already-authorized local messages without navigation or another Enter.

Every new decision dispatch supersedes an earlier Home receipt. Home Goal opening
aligns the Planning cursor with filtered/sorted visible rows before bracket
navigation. Creation rejects known local collisions and sends `create_only=true`
so the backend refuses reconfiguration; only typed Created receipts clear the
retained declaration. The public schema documents this field. A production-handler
test asserts existing metadata, owner projection and both TOML files remain
unchanged on refusal. These fixes await current-head execution.

Native probe run36673326151 succeeded at ba0a831, which precedes these fixes.
The installed c112 server rejects the new create-only argument; completing real
creation requires the matching new server companion as well as the TUI. No old
server mutation fallback or UI-only installation can close that journey.

## Scoped navigation and composer follow-up

Home entry through the surface strip now saves the complete recipient-bound
composer draft and releases its focus. The mouse-entry fixture checks that Home
Enter opens a destination before an explicit chat send, preserving text and media.
Scoped HTTP bundles carry a freshly read workspace identity and share an ordered
dispatch ticket with full refreshes. Superseded success, failure and booting
results cannot restore authority or overwrite datasets. A newer full refresh
reads all current surface datasets when it supersedes a scoped read. The
switch-less scoped path uses the same success/failure and queue recovery logic.
These changes require a newly built executable; parse checks are not proof.

The source-specific native artifact from run 36690672472 at
`6be390c6dfcfe31e388dace1d5e4247d10a0ae4c` passed the two question recovery
fixture scenarios after its ZIP and file checksums and executable source identity
were verified. This closes the before-fix Ask reproducer only at that head; it
precedes the latest main integration and scoped/composer changes. The new suites
`test_tui_home_composer_focus_pty` and `test_tui_home_scoped_identity_pty` cover
these remaining transitions. Local queue checks use the complete displayed
`tui-<UUID>` and real mouse navigation; chat text is not a palette command.

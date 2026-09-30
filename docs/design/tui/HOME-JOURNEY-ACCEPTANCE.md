# Home journey acceptance

2026-09-30. Implementation under review: PR #39817, source head
`6ac4da4e23d3a1a66422c76e89ebad102dbcf5f3`. Parent #38801 merged on
2026-09-29. This checklist records remaining acceptance work; it is not a
runtime-success or merge verdict.

The current Home is a destination summary: requests open Approvals or Agenda,
and continuation opens an explicitly visited conversation or Keeper selection.
It does not yet render individual request cards or persist a last conversation
independently of `opening = "last"`. Those limitations remain part of the full
Home journey work, rather than being treated as completed requirements.

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
| Overview startup remembers a last conversation across restarts | `home_last_chat` is session-only | Independent durable navigation receipt and restart/deletion verification |
| All sources retain their distinct decision identity | Home currently aggregates destinations | Individual request projection with kind + authoritative request ID; duplicate and same-task cases |
| Acceptance sizes and color-independent actions | `test_tui_home_viewports_pty.py`: 80×24, 120×32, 160×48, normal and NO_COLOR | Execute new suite; inspect its 12 complete PTY frames |
| Large queues preserve continuation and reach every request | Home aggregates queue; details own their paging | Overflow journey through details and back with selection restored |
| Accepted decisions distinguish receipt from application | Existing detail actions | Accepted-but-not-applied fixture and fresh-read verification |
| Usage entry is independent of prior Telemetry visit | Existing Usage keyboard scenario | Current-head targeted suite and rendered Usage evidence |
| Improved time to first action | No user timing measurement here | Same-task before/after operator observation; do not infer speed from layout |

The viewport suite deliberately captures fresh full redraws after actual size
changes. It checks terminal row addresses as well as text, emits raw base64 PTY
frames as `HOME_JOURNEY_FRAME`, and rejects product POSTs during navigation.
These are synthetic fixture observations when executed. They cannot prove
Keeper operation, production readiness, installation, or human action timing.

Run the focused acceptance in CI with:

```sh
gh workflow run test.yml --ref <branch> -f suite=test_tui_home_viewports_pty
```

No local Dune build is needed. Current-head required PR checks, focused test
results, binary provenance, fixture screenshots and production observations
must remain separate evidence. A passing viewport suite closes only its row.

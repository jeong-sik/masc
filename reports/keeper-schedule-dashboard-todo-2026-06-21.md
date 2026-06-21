# Keeper Schedule Dashboard Todo

Date: 2026-06-21 KST
Scope: keeper scheduled automation implementation and dashboard exposure.
Base revision inspected: `2eed0aa22454cec6b2ec747dbdb468890ea8527f` (`origin/main` at inspection time).

## Verdict

The schedule substrate is real, but the operator-facing product is not done.

Implemented: durable schedule records, recurrence metadata, separate human grant policy, due scanning, dispatch signals, schedule tools, a board-post consumer, keeper prompt observations, and a Tools/Lab dashboard panel.

Not done: broad keeper job execution, active tool-surface exposure, top-level system dashboard visibility, live deployment parity, and an end-to-end live happy-path proof. Current live data also contains schedules for payload kinds that the only server consumer does not support.

## Evidence

Code paths inspected:

- Schedule domain/store/service/runner:
  - `lib/schedule/schedule_domain.mli`
  - `lib/schedule/schedule_store.mli`
  - `lib/schedule/schedule_service.mli`
  - `lib/schedule/schedule_runner.mli`
  - `lib/schedule/schedule_runner.ml`
- Server loop:
  - `lib/server/server_bootstrap_maintenance.ml`
  - `lib/server/server_runtime_bootstrap.ml`
- Concrete consumers:
  - `lib/server/server_schedule_consumers.ml`
- Tool schema and dispatch:
  - `lib/tool_schemas/tool_schemas_schedule.ml`
  - `lib/tool_schedule.ml`
  - `lib/keeper/keeper_tool_descriptor.ml`
- Keeper read model and prompt:
  - `lib/keeper/keeper_world_observation.ml`
  - `lib/keeper/keeper_unified_prompt.ml`
  - `lib/schedule_projection.ml`
- Dashboard API and UI:
  - `lib/server/server_dashboard_http_runtime_info.ml`
  - `dashboard/src/api/dashboard.ts`
  - `dashboard/src/components/tools/tools-main.ts`
  - `dashboard/src/components/tools/scheduled-automation-panel.ts`
  - `dashboard/src/components/tools/tools-main.test.ts`

Live runtime checked:

- `GET http://127.0.0.1:8935/health?full=1`
- `GET http://127.0.0.1:8935/api/v1/dashboard/tools`
- Live release: `0.19.47`
- Live runtime source snapshot: `76d88e2bc0`
- Repo head / inspected main: `2eed0aa224`
- Runtime warning: source snapshot differs from server repo HEAD; rebuild/restart is required before trusting dashboard identity.
- Live schedule projection exists with schema `masc.dashboard.scheduled_automation.v1`.
- Live schedule counts: `failed=2`, `expired=2`, all active/due/blocked counts are `0`.
- Live scheduled payload kinds:
  - `backlog_depletion_check` -> expired
  - `orphan_auto_release` -> failed, unsupported payload kind
  - `task_goal_generation` -> expired
  - `keeper_surface_post` -> failed, unsupported payload kind
- Live schedule tools:
  - `masc_schedule_create`
  - `masc_schedule_list`
  - `masc_schedule_get`
  - `masc_schedule_cancel`
  - `masc_schedule_approve`
  - `masc_schedule_reject`
- All live schedule tools report `direct_call_allowed=true` and `dispatch_registered=true`, but `surfaces=[]` and `enabled_in_current_mode=false`.

## Implementation Matrix

| Area | Status | Notes |
| --- | --- | --- |
| Durable schedule model | Done | Actor/risk/status/source, one-shot/interval/daily/cron recurrence, payload envelope, grants, execution records. |
| Durable store | Done | `schedules.json`, last-good recovery, due refresh, recurring reschedule, due candidate start/complete/fail paths. |
| Schedule service | Done | Create/list/get/approve/reject/cancel/due-candidate API. It intentionally does not execute work. |
| Runtime runner | Done | Background maintenance fiber ticks `Schedule_runner.tick` and emits due/blocked signals. |
| At-most-once signal ledger | Done | Signal files and signal-key ledger exist under `.masc/schedules`. |
| Concrete job consumers | Partial | Only `masc.board_post` is accepted by `Server_schedule_consumers`. Existing live payload kinds are mostly unsupported. |
| Schedule tools | Partial | Schemas and dispatch exist, but live dashboard says schedule tools have no active tool surface. |
| Keeper prompt observation | Partial | Main has scheduled automation prompt/read-model wiring. Live runtime is behind and lacks the newest keeper next-action row fields. |
| Dashboard API projection | Partial | Main emits `scheduled_automation` with request rows and keeper next actions. Live server is stale relative to main. |
| Dashboard UI | Partial | Tools/Lab panel renders FSM, counts, requests, readiness, payload, recurrence, and last run. It is not visible in the first operational/system view. |
| Operator actions in UI | Missing | The panel is read-only; no approve/reject/cancel/get/create affordances or deep links are wired. |
| Live happy-path proof | Missing | No active due/approved supported schedule is present. Current live state only proves terminal/unsupported/expired cases. |

## Adversarial Findings

### P0-1: Live dashboard is stale relative to inspected main

Current live runtime reports source snapshot `76d88e2bc0`, while repo head is `2eed0aa224`. The latest schedule dashboard and keeper next-action work is on main but cannot be assumed deployed.

Impact: an operator looking at the dashboard can see incomplete schedule rows and may misdiagnose UI bugs that are actually stale binary/runtime identity.

Todo:

- Rebuild/restart the runtime from current main.
- Re-check `/api/v1/dashboard/tools` after restart.
- Require `runtime_repo_head_git_commit == server_repo_git_commit` or a known binary commit before calling the schedule dashboard current.

Acceptance:

- Runtime identity no longer warns about `76d88e2bc0` vs `2eed0aa224`.
- `scheduled_automation.requests[*].keeper_next_tool` and `keeper_next_action` appear for non-terminal rows on a fresh runtime.

### P0-2: Prompt suggests schedule tools that are not exposed in the active surface

The keeper prompt/read-model can tell keepers to use `masc_schedule_get`, `masc_schedule_approve`, or `masc_schedule_reject`. Live tool inventory reports every `masc_schedule_*` tool with `surfaces=[]` and `enabled_in_current_mode=false`.

Impact: the system can generate a next action that the active tool surface does not advertise as usable. This is a contract mismatch, not a cosmetic issue.

Todo:

- Decide the intended schedule tool surface: operator-only, keeper-internal, or both.
- Add the six `masc_schedule_*` tools to the proper `Tool_catalog_surfaces` / keeper tool surface.
- Add a regression test that checks both descriptor registration and active surface exposure.
- If these tools must stay hidden, remove or rewrite keeper prompt actions that instruct keepers to call them.

Acceptance:

- Dashboard tool inventory shows schedule tools enabled on the intended surface.
- Keeper prompt next actions only reference tools that the keeper can actually call.

### P0-3: Existing live schedules use unsupported payload kinds

The only concrete consumer supports `masc.board_post`. Live schedule records include `orphan_auto_release`, `keeper_surface_post`, `task_goal_generation`, and `backlog_depletion_check`.

Impact: "schedule job" exists as a ledger, but not as a general Keeper schedule worker. Real-looking jobs either expire silently or fail as unsupported. This will erode trust quickly because the dashboard can show a schedule while the runner cannot do the work.

Todo:

- Add a consumer registry that declares supported payload kinds.
- Implement or explicitly retire the currently observed payload kinds:
  - `keeper_surface_post`
  - `orphan_auto_release`
  - `task_goal_generation`
  - `backlog_depletion_check`
- Surface unsupported payload kind counts in the dashboard summary.
- Avoid permanently failing unsupported payloads without a remediation path, or make the terminal failure explicitly actionable.

Acceptance:

- Creating a schedule with an unsupported payload kind fails at create time or is displayed as unsupported before due time.
- Existing unsupported schedule records have a documented migration/remediation path.

### P1-1: Dashboard exposure is buried in Tools/Lab

`ScheduledAutomationPanel` is mounted in the tools inventory page. That is useful for debugging, but weak for "system dashboard" monitoring.

Impact: an operator watching the main dashboard/keeper detail/attention surfaces can miss a blocked approval or failed schedule unless they know to open Tools/Lab.

Todo:

- Add a compact scheduled automation card to the system overview or runtime/attention area.
- Show at least: FSM state, next due, blocked approval count, due-ready count, failed unsupported count.
- Link from the compact card to the full Tools/Lab panel.

Acceptance:

- Blocked approval and due-ready schedule states are visible without opening the tool inventory.
- The full table remains available for investigation.

### P1-2: UI is read-only where operators need decisions

The panel renders `operator_action`, `approval_policy`, and readiness, but does not expose approve/reject/cancel/get actions.

Impact: the dashboard tells the operator a decision is needed but forces a manual tool call outside the UI.

Todo:

- Add explicit action affordances for:
  - `masc_schedule_get`
  - `masc_schedule_approve`
  - `masc_schedule_reject`
  - `masc_schedule_cancel`
- Gate side-effecting actions behind the existing human grant model.
- Keep action results visible in the row's last execution / status area.

Acceptance:

- A blocked approval can be inspected and approved/rejected from the dashboard.
- A terminal/expired schedule can be inspected and recreated intentionally.

### P1-3: Runtime parser coverage is thin

The TypeScript API type declares `scheduled_automation`, and the component test renders a fixture. There is no strong runtime parser or schema drift guard around this projection.

Impact: backend field drift can silently degrade the UI. The live/main mismatch around newer row fields is exactly the kind of issue this should catch.

Todo:

- Add a dashboard API normalization/parser for `scheduled_automation`.
- Totalize missing optional fields, but fail or warn on missing required fields such as `requests`, `counts`, and `fsm`.
- Add fixture tests for:
  - active scheduled item
  - blocked approval
  - unsupported payload failure
  - stale/older projection without keeper next-action fields

Acceptance:

- A malformed `scheduled_automation` response produces an explicit UI/API warning instead of silent blank or partial rendering.

### P1-4: No live-safe happy-path smoke exists

Current live state proves terminal records and unsupported payload failures, not successful due dispatch.

Impact: the runtime may look wired while the most important path, due approved supported schedule -> consumer dispatch -> execution record -> dashboard update, remains unproven.

Todo:

- Add a safe no-op or test-only schedule payload kind, or a live-safe `masc.board_post` smoke fixture.
- Run the smoke against `/Users/dancer/me/.masc` only when explicitly intended.
- Capture before/after dashboard projection evidence.

Acceptance:

- One due schedule transitions through ready/running/succeeded in a local smoke without corrupting operational board state.

### P2-1: Runner liveness is not a first-class dashboard signal

The schedule panel derives schedule state, but it does not show the last runner tick, last dispatch attempt, or stale-runner warning.

Impact: if the scheduler fiber dies or stops ticking, operators may see stale scheduled rows without an obvious scheduler-health failure.

Todo:

- Add runner telemetry: last tick time, last tick error, emitted/dispatch/rescheduled counters.
- Surface stale-runner state in the overview card and full panel.

Acceptance:

- Killing or breaking the schedule runner produces a visible dashboard warning.

### P2-2: Recurrence is metadata-rich but operationally under-explained

The model supports interval/daily/cron/fixed-offset timezone contracts, but the UI mainly displays summaries.

Impact: recurring schedules can be hard to audit for "why did this run now?" or "when will it run next?".

Todo:

- Add next-run and previous-run fields for recurring schedules.
- Add a recurrence explanation string in the projection.
- Add tests for daily fixed-offset behavior around date boundaries.

Acceptance:

- A recurring schedule row explains last due, next due, timezone offset, and reschedule outcome.

## Recommended Next Order

1. Rebuild/restart runtime and re-check dashboard projection parity.
2. Fix schedule tool surface exposure or remove tool-call instructions from keeper prompts.
3. Add consumer registry plus unsupported payload visibility.
4. Move a compact schedule status card into the main operational dashboard.
5. Add one live-safe happy-path smoke.
6. Add dashboard parser/fixture tests around `scheduled_automation`.

## Done Criteria For This Feature

Do not call Keeper scheduling "done" until all of these are true:

- Current runtime is built from current main or exposes a known binary commit.
- The dashboard can show active, due, blocked, failed, and succeeded schedules.
- The dashboard exposes blocked approvals in an operational surface, not only Tools/Lab.
- Keeper prompts only mention schedule tools that are actually callable in that context.
- Unsupported payload kinds cannot quietly become terminal surprises.
- At least one supported schedule completes end-to-end and leaves an execution record visible in the dashboard.

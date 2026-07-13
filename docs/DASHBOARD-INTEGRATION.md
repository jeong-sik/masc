---
status: reference
last_verified: 2026-05-20
code_refs:
  - dashboard/src/config/navigation.ts
  - dashboard/src/components/status.ts
  - dashboard/src/components/work.ts
  - dashboard/src/components/lab.ts
  - lib/dashboard/dashboard_surface_readiness.ml
---

# Dashboard Integration Spec (v1 Shell)

## Goal
- Dashboard v1의 canonical shell contract를 한 문서에 고정한다.
- top-level tab과 in-surface sub-view를 분리해 설명한다.
- legacy deep link redirect는 보존하되 readiness inventory의 정답은 current v1 navigation으로 제한한다.

## Base
- Base URL: `http://127.0.0.1:8935`
- REST Base: `/api/v1`
- SSE observer: `/mcp?sse_kind=observer`
- MCP: `/mcp`

## Auth
- HTTP Header
  - `Authorization: Bearer <token>`
  - `X-MASC-Agent: <agent_name>`
- SSE
  - `/mcp?agent=<agent_name>&token=<token>&session_id=<session_id>&sse_kind=observer`

## Canonical v1 Surfaces

### Top-level tabs
- `cockpit` (hidden)
- `overview`
- `monitoring`
- `command`
- `connectors`
- `workspace`
- `lab`
- `code`
- `logs`

### Section inventory
- `cockpit`
  - `#cockpit` (hidden)
- `overview`
  - `#overview`
- `monitoring`
  - `#monitoring?section=agents` — Keeper Operations (default)
  - `#monitoring?section=fleet-health` — Tool Monitor
  - `#monitoring?section=runtime` — Runtime & Runtime
  - `#monitoring?section=observatory` — Evidence Timeline
  - `#monitoring?section=runtime-config` (hidden diagnostic)
  - `#monitoring?section=diagnostics` (hidden diagnostic)
  - `#monitoring?section=transport-health` (hidden diagnostic)
  - `#monitoring?section=feature-health` (hidden diagnostic)
  - `#monitoring?section=journey` (hidden diagnostic)
  - `#monitoring?section=cognition` (hidden deep link; keeper detail cognition path)
- `command`
  - `#command?section=operations`
  - sub-view는 `view=ops|gate|surfaces|inspector` 로 분기한다.
  - legacy `#command?section=connectors` / `#command/connectors` 는 `#connectors?section=connector-status` 로 canonical redirect 된다.
- `connectors`
  - `#connectors?section=connector-status`
- `workspace`
  - `#workspace?section=board`
  - `#workspace?section=sub-boards`
  - `#workspace?section=planning`
  - `#workspace?section=repositories`
  - `#workspace?section=verification`
- `lab`
  - `#lab?section=tools`
  - `#lab?section=harness`
- `code`
  - `#code?section=ide-shell`
- `logs`
  - `#logs`

## Legacy Redirect Contract
- `monitoring:sessions -> monitoring:agents`
- `monitoring:activity -> monitoring:observatory`
- `monitoring:live -> monitoring:observatory&view=live`
- `monitoring:telemetry -> monitoring:fleet-health&view=event-log`
- `monitoring:fleet -> monitoring:fleet-health&view=comparison`
- `monitoring:tool-quality -> monitoring:fleet-health&view=tool-quality`
- `monitoring:governance -> monitoring:fleet-health&view=gate`
- `monitoring:attribution -> monitoring:fleet-health&view=attribution`
- `monitoring:fsm-hub -> monitoring:agents&view=fsm`
- `monitoring:metrics -> monitoring:runtime`
- `monitoring:runtime-inspector -> monitoring:runtime&view=inspector`
- `monitoring:cost -> monitoring:runtime&view=cost`
- `monitoring:git-graph -> workspace:repositories`
- `command:intervene -> command:operations`
- `command:governance -> command:operations`
- `command:connectors -> connectors:connector-status`
- `command:inspector -> command:operations&view=inspector`
- `connectors:connector-discord -> connectors:connector-status&connector=discord`
- `connectors:connector-imessage -> connectors:connector-status&connector=imessage`
- `connectors:connector-slack -> connectors:connector-status&connector=slack`
- `connectors:connector-telegram -> connectors:connector-status&connector=telegram`
- `workspace:goals -> workspace:planning`

이 redirect는 router/navigation 호환성 계약이다. `surface-readiness`에는 legacy surface를 다시 등재하지 않는다.

## Monitor IA Contract
- Monitor default는 `#monitoring?section=agents` 이다.
- visible Monitor sidebar는 네 개의 primary lane만 가진다.
  - Keeper Operations: attention-first keeper/agent list and selected detail.
  - Tool Monitor: compact tool operations board plus tool-quality, Gate, attribution, and event-log lenses.
  - Runtime & Runtime: provider/runtime health and advanced runtime sub-views.
  - Evidence Timeline: default evidence track timeline with explicit Activity Graph and Live lenses.
- `runtime-config`, `diagnostics`, `transport-health`, `feature-health`, `journey`, `cognition`은 routeable compatibility/diagnostic/deep-link surface로 남지만 primary sidebar에는 노출하지 않는다.
- Keeper Cognition은 top-level Monitor sibling이 아니라 Keeper Operations의 selected keeper detail/deep-link path로 취급한다.
- Keeper Operations selected detail은 `Cognition`, `Tool Access`, `Runtime Trace` lens를 통해 hidden/deep-link surfaces로 연결한다.
- Tool Monitor default view는 full telemetry/full quality panels를 나란히 터뜨리지 않고 tool success, failures, attention tools, failure categories, and lane links만 먼저 보여준다.
- Evidence Timeline default view는 Activity Graph card panels를 자동으로 붙이지 않는다. Activity Graph는 `#monitoring?section=observatory&view=activity`, Live는 `#monitoring?section=observatory&view=live`에서만 열린다.
- Transport/Feature/Diagnostics 상세는 Monitor daily default가 아니라 diagnostics/admin 성격이다. Monitor에는 degraded badge나 diagnostic link만 노출한다.
- Runtime & Runtime default view는 OAS/runtime signal을 먼저 보여주고 `transport-health`, `diagnostics`, `feature-health`를 hidden diagnostics link 묶음으로 노출한다.

## Canonical Read Models
- `GET /api/v1/dashboard/shell`
  - overview + runtime shell metadata
- `GET /api/v1/dashboard/namespace-truth`
  - journey / agents / shared namespace truth
- `GET /api/v1/dashboard/goal-loop/status`
  - goal navigator runtime status
- `GET /api/v1/activity/graph`
  - observatory investigation graph
- `GET /api/v1/dashboard/telemetry/summary`, `GET /api/v1/dashboard/telemetry?source=tool_call_io`
  - Tool Monitor evidence-log lens and source freshness metadata
- `GET /api/v1/dashboard/oas/telemetry/recent`, `GET /api/v1/dashboard/oas/telemetry/summary`
  - in-process OAS runtime-lane sample cache; payloads expose `dashboard_surface`, `source`, and `retention.durable_replay_surface` so operators can distinguish cache state from durable `oas_event` replay
- `GET /api/v1/dashboard/memory-subsystems`
  - cognition memory sub-view read model
- `GET /api/v1/attribution/summary`
  - fleet-health attribution view
- `GET /api/v1/dashboard/transport-health`
  - runtime transport health + connection freshness view
- `GET /api/v1/dashboard/keeper-feature-proof`
  - keeper autonomy feature proof gates, including 24h turn-span and web-search tool evidence
  - tool gates count only calls from known keeper names and expose `keeper_evidence.provenance_scope=known_keeper_tool_call_log`, per-tool successful/failing keepers, sandbox/network modes, task IDs, and goal IDs
  - read-only CLI equivalent: `masc-keeper-feature-proof --base-path <runtime-root>`
- `GET /api/v1/models/metrics`, `GET /api/v1/dashboard/keeper-costs`
  - runtime cost/latency view
- `GET /api/v1/dashboard/keeper-decisions`
  - runtime decision and heuristic feeds; payloads expose `dashboard_surface`, `source`, and `retention` so the Cost/Runtime subviews can distinguish visible read-model state from the backing JSONL logs
- `GET /api/v1/providers`
  - runtime provider inventory
- `GET /api/v1/runtime/config`, `GET /api/v1/runtime/config/raw`
  - runtime runtime config inspector read models
- `GET /api/v1/runtime/client_capacity`, `GET /api/v1/runtime/client_capacity/history`, `GET /api/v1/runtime/slo`
  - runtime runtime capacity + SLO view
- `GET /api/v1/runtime/strategy_trace`, `GET /api/v1/runtime/health`
  - runtime inspector view
- `GET /api/v1/operator/digest`
  - operations read model
- `GET /api/v1/gate/connectors`
  - connectors descriptor + live state
- `GET /api/v1/dashboard/board`
  - workspace board
- `GET /api/v1/board/hearths`, `GET /api/v1/board/curation`, `GET /api/v1/board/karma/ledger`
  - workspace board filters, curation, and karma ledger
- `GET /api/v1/board/sub-boards`
  - workspace named board spaces
- `GET /api/v1/dashboard/planning`
  - planning + goal tree
- `GET /api/v1/repositories`, `GET /api/v1/workspace/tree`
  - workspace repository registry and source tree browser read models
- `GET /api/v1/verification/requests`, `GET /api/v1/verification/summary`
  - workspace verification table and status rollup
- `GET /api/v1/verification/specs`, `GET /api/v1/verification/tlc-results`
  - TLA+ spec index and TLC result panels
- `GET /api/v1/dashboard/tools`
  - lab tools inventory
- `GET /api/v1/dashboard/tool-quality`, `GET /api/v1/tool-metrics`, `GET /api/v1/prompts`
  - lab tool quality aggregates, unified usage metrics, and prompt registry read model
- `GET /api/v1/dashboard/harness-health`
  - lab harness health
- `GET /api/v1/ide/annotations`, `GET /api/v1/ide/regions`, `GET /api/v1/ide/presence`
  - code IDE annotations, source regions, and live collaboration presence
- `GET /api/v1/dashboard/logs`
  - log viewer
- `GET /api/v1/dashboard/surface-readiness`
  - canonical surface inventory + readiness refs

## Supporting / Compatibility Read Models
- `GET /api/v1/dashboard/briefing`
- `GET /api/v1/dashboard/briefing/sections`
- `GET /api/v1/dashboard/execution`
- `GET /api/v1/dashboard/gate`
- `GET /api/v1/dashboard/proof`
  - compatibility proof index over verification requests, TLA result refs, keeper feature proof, execution trust, and surface readiness routes
- `GET /api/v1/dashboard/goals`
- `GET /api/v1/dashboard/config`
- `GET /api/v1/dashboard/feature-health`

이 endpoint들은 current v1 shell의 top-level navigation contract가 아니라 supporting read model이다.

## SSE Expectations
- SSE는 freshness transport다. canonical hydration source는 REST projection이다.
- dashboard observer session은 live `oas:*` tail과 durable replay를 함께 본다.
- 현재 v1 shell이 직접 반응하는 최소 이벤트 클래스:
  - `broadcast`
  - `task_*`
  - `agent_bound`
  - `agent_unbound`
  - `board_post`
  - `board_comment`
  - `decision_*`
  - `operator_*`

## Error Contract
- JSON responses only
- Auth failure
  - `401 Unauthorized`
  - `{"error":"unauthorized"}`
- Permission failure
  - `403 Forbidden`
  - `{"error":"forbidden"}`
- Removed legacy batch endpoint
  - `410 Gone`
  - `{"error":"dashboard batch contract removed", ...}`

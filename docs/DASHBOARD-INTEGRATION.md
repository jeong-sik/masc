---
status: reference
last_verified: 2026-05-01
code_refs:
  - dashboard/src/config/navigation.ts
  - dashboard/src/components/status.ts
  - dashboard/src/components/control.ts
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
- SSE: `/sse`
- MCP: `/mcp`

## Auth
- HTTP Header
  - `Authorization: Bearer <token>`
  - `X-MASC-Agent: <agent_name>`
- SSE
  - `/sse?agent=<agent_name>&token=<token>`

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
  - `#monitoring?section=runtime`
  - `#monitoring?section=agents`
  - `#monitoring?section=goal-loop`
  - `#monitoring?section=fleet-health`
  - `#monitoring?section=journey` (hidden diagnostic)
  - `#monitoring?section=observatory` (hidden diagnostic)
  - `#monitoring?section=cognition` (hidden diagnostic)
- `command`
  - `#command?section=operations`
  - sub-view는 `view=ops|governance|safety|inspector|connectors` 로 분기한다.
  - `view=connectors` 는 `#connectors?section=connector-status` 로 canonical redirect 된다.
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
  - `#lab?section=autoresearch`
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
- `monitoring:governance -> monitoring:fleet-health&view=governance`
- `monitoring:attribution -> monitoring:fleet-health&view=attribution`
- `monitoring:fsm-hub -> monitoring:agents&view=fsm`
- `monitoring:metrics -> monitoring:runtime`
- `monitoring:cascade-inspector -> monitoring:runtime&view=inspector`
- `monitoring:cost -> monitoring:runtime&view=cost`
- `monitoring:git-graph -> workspace:repositories&view=graph`
- `monitoring:safe-autonomy -> command:operations&view=safety`
- `command:intervene -> command:operations`
- `command:governance -> command:operations`
- `command:connectors -> command:operations&view=connectors`
- `command:inspector -> command:operations&view=inspector`
- `connectors:connector-discord -> connectors:connector-status&connector=discord`
- `connectors:connector-imessage -> connectors:connector-status&connector=imessage`
- `connectors:connector-slack -> connectors:connector-status&connector=slack`
- `connectors:connector-telegram -> connectors:connector-status&connector=telegram`
- `workspace:goals -> workspace:planning`

이 redirect는 router/navigation 호환성 계약이다. `surface-readiness`에는 legacy surface를 다시 등재하지 않는다.

## Canonical Read Models
- `GET /api/v1/dashboard/shell`
  - overview + runtime shell metadata
- `GET /api/v1/dashboard/namespace-truth`
  - journey / agents / shared namespace truth
- `GET /api/v1/dashboard/goal-loop/status`
  - goal navigator runtime status
- `GET /api/v1/activity/graph`
  - observatory investigation graph
- `GET /api/v1/dashboard/telemetry/summary`
  - fleet-health summary
- `GET /api/v1/dashboard/memory-subsystems`
  - cognition memory sub-view read model
- `GET /api/v1/attribution/summary`
  - fleet-health attribution view
- `GET /api/v1/dashboard/safe-autonomy`
  - operations safety view
- `GET /api/v1/dashboard/transport-health`
  - runtime transport health + connection freshness view
- `GET /api/v1/dashboard/keeper-feature-proof`
  - keeper autonomy feature proof gates, including 24h turn-span and web-search tool evidence
  - tool gates count only calls from known keeper names and expose `keeper_evidence.provenance_scope=known_keeper_tool_call_log`, per-tool successful/failing keepers, sandbox/network modes, task IDs, and goal IDs
  - Docker git-to-PR workflow proof exposes clone, branch, commit, push, and draft-PR creation as separate keeper-originated stages
  - read-only CLI equivalent: `masc-keeper-feature-proof --base-path <runtime-root>`
- `GET /api/v1/models/metrics`, `GET /api/v1/dashboard/keeper-costs`
  - runtime cost/latency view
- `GET /api/v1/providers`
  - runtime provider inventory
- `GET /api/v1/cascade/config`, `GET /api/v1/cascade/config/raw`
  - runtime cascade config inspector read models
- `GET /api/v1/cascade/client_capacity`, `GET /api/v1/cascade/client_capacity/history`, `GET /api/v1/cascade/slo`
  - runtime cascade capacity + SLO view
- `GET /api/v1/cascade/strategy_trace`, `GET /api/v1/cascade/health`
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
- `GET /api/v1/git/graph`
  - workspace repository graph view
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
- `GET /api/v1/autoresearch/loops`
  - lab autoresearch loops
- `GET /api/v1/dashboard/harness-health`
  - lab harness health
- `GET /api/v1/ide/annotations`, `GET /api/v1/ide/regions`, `GET /api/v1/ide/presence`
  - code IDE annotations, source regions, and live collaboration presence
- `GET /api/v1/dashboard/logs`
  - log viewer
- `GET /api/v1/dashboard/surface-readiness`
  - canonical surface inventory + readiness refs

## Supporting / Compatibility Read Models
- `GET /api/v1/dashboard/mission`
- `GET /api/v1/dashboard/execution`
- `GET /api/v1/dashboard/governance`
- `GET /api/v1/dashboard/proof`
- `GET /api/v1/dashboard/goals`
- `GET /api/v1/dashboard/config`
- `GET /api/v1/dashboard/feature-health`

이 endpoint들은 여전히 남아 있을 수 있지만 current v1 shell의 top-level navigation contract는 아니다.

## SSE Expectations
- SSE는 freshness transport다. canonical hydration source는 REST projection이다.
- dashboard observer session은 live `oas:*` tail과 durable replay를 함께 본다.
- 현재 v1 shell이 직접 반응하는 최소 이벤트 클래스:
  - `broadcast`
  - `task_*`
  - `agent_joined`
  - `agent_left`
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

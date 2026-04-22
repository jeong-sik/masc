---
status: reference
last_verified: 2026-04-22
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
- `overview`
- `monitoring`
- `command`
- `connectors`
- `workspace`
- `lab`
- `logs`

### Section inventory
- `overview`
  - `#overview`
- `monitoring`
  - `#monitoring?section=journey`
  - `#monitoring?section=observatory`
  - `#monitoring?section=agents`
  - `#monitoring?section=runtime`
  - `#monitoring?section=fleet-health`
  - `#monitoring?section=memory-subsystems`
  - `#monitoring?section=attribution`
- `command`
  - `#command?section=operations`
  - sub-view는 `view=ops|governance|inspector|connectors` 로 분기한다.
  - `view=connectors` 는 `#connectors?section=connector-status` 로 canonical redirect 된다.
- `connectors`
  - `#connectors?section=connector-status`
  - `#connectors?section=connector-discord`
  - `#connectors?section=connector-imessage`
  - `#connectors?section=connector-slack`
  - `#connectors?section=connector-telegram`
- `workspace`
  - `#workspace?section=board`
  - `#workspace?section=planning`
  - `#workspace?section=verification`
- `lab`
  - `#lab?section=tools`
  - `#lab?section=autoresearch`
  - `#lab?section=harness`
- `logs`
  - `#logs`

## Legacy Redirect Contract
- `monitoring:sessions -> monitoring:agents`
- `monitoring:activity -> monitoring:observatory`
- `monitoring:telemetry -> monitoring:fleet-health&view=event-log`
- `monitoring:fleet -> monitoring:fleet-health&view=comparison`
- `monitoring:tool-quality -> monitoring:fleet-health&view=tool-quality`
- `monitoring:governance -> monitoring:fleet-health&view=governance`
- `monitoring:fsm-hub -> monitoring:agents&view=fsm`
- `monitoring:metrics -> monitoring:runtime`
- `command:intervene -> command:operations`
- `command:governance -> command:operations`
- `command:connectors -> command:operations&view=connectors`
- `command:inspector -> command:operations&view=inspector`
- `workspace:goals -> workspace:planning`

이 redirect는 router/navigation 호환성 계약이다. `surface-readiness`에는 legacy surface를 다시 등재하지 않는다.

## Canonical Read Models
- `GET /api/v1/dashboard/shell`
  - overview + runtime shell metadata
- `GET /api/v1/dashboard/namespace-truth`
  - journey / agents / shared namespace truth
- `GET /api/v1/activity/graph`
  - observatory investigation graph
- `GET /api/v1/dashboard/telemetry/summary`
  - fleet-health summary
- `GET /api/v1/dashboard/memory-subsystems`
  - memory subsystem health
- `GET /api/v1/attribution/summary`
  - attribution gate summary
- `GET /api/v1/operator/digest`
  - operations read model
- `GET /api/v1/gate/connectors`
  - connectors descriptor + live state
- `GET /api/v1/dashboard/board`
  - workspace board
- `GET /api/v1/dashboard/planning`
  - planning + goal tree
- `GET /api/v1/verification/requests`
  - workspace verification table
- `GET /api/v1/dashboard/tools`
  - lab tools inventory
- `GET /api/v1/autoresearch/loops`
  - lab autoresearch loops
- `GET /api/v1/dashboard/harness-health`
  - lab harness health
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

---
status: reference
---

# Dashboard Integration Spec

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

## Canonical Read Models
- `GET /api/v1/dashboard/shell`
  - overview + runtime shell metadata
- `GET /api/v1/dashboard/project-snapshot`
  - journey / agents / shared project snapshot
  - goal navigator runtime status
- `GET /api/v1/dashboard/telemetry/summary`, `GET /api/v1/dashboard/telemetry?source=tool_call_io`
  - Tool Monitor evidence-log lens and source freshness metadata
- `GET /api/v1/attribution/summary`
  - fleet-health attribution view
- `GET /api/v1/dashboard/transport-health`
  - runtime transport health + connection freshness view
- `GET /api/v1/diagnostics/heap-roots`
  - admin-only: reachable size of each registered heap root; stalls the process for the walk
- `GET /api/v1/models/metrics`, `GET /api/v1/dashboard/keeper-costs`
  - runtime cost/latency view
- `GET /api/v1/dashboard/keeper-decisions`
  - runtime decision and heuristic feeds; payloads expose `dashboard_surface`, `source`, and `retention` so the Cost/Runtime subviews can distinguish visible read-model state from the backing JSONL logs
- `GET /api/v1/providers`
  - runtime provider inventory
- `GET /api/v1/runtime/config/raw`
  - runtime runtime config inspector read models
- `GET /api/v1/operator/digest`
  - operations read model
- `GET /api/v1/gate/connectors`
  - connectors descriptor + live state
- `GET /api/v1/dashboard/board`
  - workspace board
- `POST /api/v1/tools/masc_board_post`, `masc_board_comment`, `masc_board_vote`, `masc_board_comment_vote`
  - Each Board write accepts optional `"expected_workspace": {"base_path": "...", "masc_root": "..."}` using the canonical paths observed in `/health`. Invalid or mismatched identities return 400 before a write, including comment votes. The route consumes this precondition before dispatching the Board tool; omitting it preserves the authenticated write behavior.
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
- `GET /api/v1/ide/file-activity`, `GET /api/v1/ide/presence`
  - durable Keeper writes by repository file, and live collaboration presence
- `GET /api/v1/dashboard/logs`
  - log viewer

## Supporting / Compatibility Read Models
- `GET /api/v1/dashboard/briefing`
- `GET /api/v1/dashboard/briefing/sections`
- `GET /api/v1/dashboard/execution`
- `GET /api/v1/dashboard/gate`
- `GET /api/v1/dashboard/goals`
- `GET /api/v1/dashboard/config`

## SSE Expectations
- SSE는 freshness transport다. canonical hydration source는 REST projection이다.
- dashboard observer session은 live `agent_core:*` tail과 durable replay를 함께 본다.
- 대시보드가 직접 반응하는 최소 이벤트 클래스:
  - `broadcast`
  - `task_*`
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

Settings Runtime configuration ownership (`Runtime > Accounts`, `Runtime > Cascade`, `Runtime > Check`) and navigation behavior are described in
[Settings Runtime workspace changes](guides/settings-runtime-workspace.md).

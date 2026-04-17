---
status: reference
last_verified: 2026-04-17
code_refs:
  - dashboard/src/
  - lib/
---

# Dashboard Integration Spec (Operator Console)

## Goal
- Expose one operator-first dashboard model instead of a mixed omnibus bundle.
- Keep each surface responsible for one judgment domain.
- Keep experimental surfaces out of the main operator navigation.

## Canonical Main Surfaces
- `mission`: what needs attention now
- `execution`: workers, tasks, keepers, continuity pressure
- `memory`: durable posts/comments only
- `governance`: debates and voting only
- `planning`: goals, MDAL loops, backlog posture
- `intervene`: mutating operator actions
- `command`: command-plane truth

Experimental features such as TRPG live under `lab`.

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

## Dashboard Read Model

### Removed
- `GET /api/v1/dashboard`
  - removed as a dashboard read model
  - returns `410 Gone`

### Canonical projections
- `GET /api/v1/dashboard/shell`
  - shell-only room status and top-level counts
- `GET /api/v1/dashboard/mission`
  - mission summary derived from operator + command truth
- `GET /api/v1/dashboard/execution`
  - `summary`, `execution_queue`, `operation_briefs`, `worker_support_briefs`, `continuity_briefs`, `offline_worker_briefs`
  - compatibility payloads remain: `agents`, `tasks`, `messages`, `keepers`
  - test fixture mode: `?fixture=execution_smoke` or `MASC_DASHBOARD_FIXTURE=execution_smoke`
- `GET /api/v1/dashboard/board`
  - `posts` plus memory-feed summary
- `GET /api/v1/dashboard/governance`
  - `debates`, `sessions`, governance summary
- `GET /api/v1/dashboard/planning`
  - `goals`, `rollup`, `mdal`, `task_backlog`

## Raw Domain Endpoints
- `/api/v1/board*`, `/api/v1/governance*`, `/api/v1/operator*`, `/api/v1/command-plane*`
- These may still exist for domain consumers or drill-down flows.
- The dashboard client should prefer the canonical projection endpoints above.

## SSE Expectations
- Treat SSE as freshness transport, not as the read model.
- Use projection endpoints for hydration after events.
- Dashboard observer sessions receive live `oas:*` tail in addition to durable replay; keeper lifecycle detail comes from `oas:masc:keeper:lifecycle`, while primary keeper state transitions remain `keeper_phase_changed`.
- Full event inventory and timing notes live in `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md`.
- Minimum event classes the operator dashboard reacts to:
  - `broadcast`
  - `task_*`
  - `agent_joined`
  - `agent_left`
  - `board_post`
  - `board_comment`
  - `decision_*`
  - `mdal_*`
  - `command_plane_*`
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

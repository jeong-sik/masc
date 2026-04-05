# OAS-MASC Boundary Contract

OAS (OCaml Agent SDK)와 MASC-MCP 사이의 역할 경계를 정의한다.

**원칙**: OAS는 MASC를 모른다. OAS의 변경은 모든 소비자에게 유익해야 한다.

```
consumer → MASC-MCP (coordination/orchestration) → OAS (agent runtime)
```

## 문서 역할 (SSOT)

- 이 문서는 **boundary contract SSOT**다.
- `/home/runner/work/masc-mcp/masc-mcp/docs/spec/13-oas-integration.md`는 구현 세부와 open issue ledger를 유지한다.
- `/home/runner/work/masc-mcp/masc-mcp/docs/qa/OAS-BOUNDARY-HEALTHCHECK-2026-03-31.md`는 시점별 health snapshot이다.
- `/home/runner/work/masc-mcp/masc-mcp/docs/design/oas-masc-state-boundary.md`는 historical audit + migration backlog로 취급한다.

## 역할 분리

| 관심사 | OAS | MASC |
|--------|-----|------|
| 단일 에이전트 실행 | `Agent.run`, `Builder`, `Hooks`, `Guardrails`, `Memory`, `Checkpoint` | 언제/왜/어떤 agent를 돌릴지 결정 |
| 멀티에이전트 실행 | `Orchestrator`, `Agent_sdk_swarm.Runner` | room, board, workflow, policies, operator surfaces |
| 도구 실행 | `Tool.t`, hook lifecycle, raw trace | tool schema 정의, tool dispatch, auth/join/policy semantics |
| 컨텍스트 축약 | `Context_reducer` | 어떤 전략을 언제 적용할지 결정 |
| 이벤트 전달 | `Event_bus` | 어떤 MASC 사건을 custom event로 publish할지 정의, SSE/dashboard에 연결 |
| 장기 메모리 프리미티브 | `Memory.t` tiers | institutional memory, pg/jsonl backends, room/task/social semantics |
| 조율 상태 | 없음 | room, tasks, team sessions, governance, social runtime |

## 의존 방향

```
MASC ──depends on──→ OAS
OAS  ──does not know──→ MASC
```

- MASC는 OAS 공개 API를 소비한다.
- MASC 전용 요구가 생겨도, 먼저 MASC adapter/bridge로 해결 가능한지 본다.
- OAS에 기능을 추가하더라도 MASC 전용 개념을 새 public contract로 밀어넣지 않는다.

## Current Integration Status

| Area | Status | Notes |
|------|--------|-------|
| Context compaction | Partial complete | `context_compact_oas.ml`는 OAS `Context_reducer`를 사용한다. MASC 전체 context system이 OAS `Context.t`로 통합된 것은 아니다. |
| Event bus bridge | Complete for current `masc:*` flow | `oas_events.ml` publishes, `oas_sse_bridge.ml` relays to dashboard SSE |
| Checkpoint integration | Partial complete | OAS checkpoint is used in shared worker/runtime paths, but keeper runtime still persists its own `working_context` / serialized checkpoint path in `lib/keeper/keeper_exec_context.ml` |
| Memory bridge | Partial complete | long-term + procedural + institution episodic are bridged; broader memory unification is still separate |
| Team-session swarm | Partial complete | OAS Swarm runner is active, delivery-contract persistence/verdict export now live, but bridge fidelity is still incomplete |

## Open Structural Gaps

- keeper runtime still uses a MASC-owned `working_context` wrapper around OAS context/checkpoint primitives
- keeper continuity still leaks domain semantics through raw message text (`[STATE]`, goal/memory markers)
- `memory_oas_bridge.ml` still owns imperative seeding/flushing instead of a hook-first boundary
- team-session bridge fidelity and runtime-health signaling are still incomplete

## Delivery-Contract Split

- MASC owns the delivery contract itself: `contract_id`, acceptance checks, required artifacts, repair budget, evaluator role/cascade, proof/report surfaces.
- OAS should stay generic and receive only reusable harness/runtime primitives.
- Current local implementation keeps the contract in team-session state and feeds it into worker verification and proof artifacts without teaching OAS about MASC session semantics.

## Candidate Upstream Work

These are the next changes that are generic enough to propose upstream:

- harness case/result/verdict/repair-directive primitives that MASC evaluators can reuse
- richer swarm `agent_entry` metadata so `planned_worker` routing and telemetry survive end to end
- structured runtime-health probe callback to replace the current boolean `resource_check`

These stay in MASC:

- room/task/board/operator/governance semantics
- planner session policy and repair-budget policy
- proof/report JSON/markdown contracts and coordination-specific evidence rules

## What This Means Practically

- “Context integration in progress” now means **broader state unification**, not compaction.
- “Event_bus bridge planned” is no longer true for the current dashboard/SSE path.
- “team_session pending migration” is no longer true; the correct description is **running on OAS Swarm with an incomplete bridge**.

## Boundary Rules for Future Work

1. If the problem is “single agent execution contract”, prefer fixing `oas_worker` / `worker_oas` / OAS-facing adapters.
2. If the problem is “room, board, governance, operator, workflow semantics”, keep it in MASC.
3. If a bridge is lossy, fix the MASC-side adapter first before proposing OAS API expansion.
4. Do not claim a subsystem is “migrated” if the runtime path works but key semantics are still dropped.

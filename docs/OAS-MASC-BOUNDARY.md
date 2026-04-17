---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/oas.ml
  - lib/oas_worker.ml
  - lib/verifier_oas.ml
  - lib/memory_oas_bridge.ml
---

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
- `/home/runner/work/masc-mcp/masc-mcp/docs/qa/OAS-OBSERVABILITY-TRUTH-AUDIT-2026-04-15.md`는 OAS observability producer -> bridge -> durable store -> dashboard consumer chain과 fixed gaps를 기록한다.
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

## Config Ownership

- `config/cascade.json`은 **OAS cascade contract**를 따르는 설정 파일이다.
- cascade schema, parsing, label semantics의 owner는 OAS다.
- MASC는 그 contract를 재정의하지 않고, 이 저장소에 체크인할 repo-level default만 선택한다.
- OAS가 소유한 설정 결과를 MASC가 소비하는 것은 허용된다. 다만 MASC는 provider allowlist, cascade parsing rule, proof-store layout 같은 OAS-owned shape를 자체 meta/profile schema로 다시 소유하면 안 된다.
- 따라서 runtime convenience label(예: `provider:auto`)은 OAS 차원에서 존재할 수 있지만, checked-in repo defaults는 review 안정성을 위해 explicit `provider:model_id`를 선호한다.
- legacy `allowed_providers` keeper TOML/meta fields는 compatibility input일 뿐이며, active runtime policy로 취급하지 않는다.
- persisted legacy keeper meta tool-policy fields are scrubbed into canonical `tool_access` on read; direct `meta_of_json` callers must use canonical keeper meta keys.

## Current Integration Status

| Area | Status | Notes |
|------|--------|-------|
| Context compaction | Partial complete | `context_compact_oas.ml`는 OAS `Context_reducer`를 사용한다. MASC 전체 context system이 OAS `Context.t`로 통합된 것은 아니다. |
| Event bus bridge | Complete for current native/custom flow | `oas_sse_bridge.ml` relays both OAS native events and `masc:*` custom events, persists them under `.masc/oas-events/`, and feeds dashboard SSE |
| Dashboard OAS runtime health | Complete with replay/live split | dashboard health SSOT is `durable oas_event replay + live SSE tail`, not live-only counters |
| Dashboard runtime counts | Complete with truth split | dashboard `counts` means active runtimes; configured keeper inventory is exposed separately as `configured_keepers` |
| Checkpoint integration | Partial complete | OAS checkpoint is used in shared worker/runtime paths, and the public OAS worker API now keeps the extra JSON as a neutral checkpoint sidecar. Keeper runtime still persists its own `working_context` / serialized checkpoint path in `lib/keeper/keeper_exec_context.ml` |
| Memory bridge | Partial complete | long-term + procedural + institution episodic are bridged; broader memory unification is still separate |
| Team-session swarm | Removed | `lib/team_session/` module purged; MASC no longer owns a session orchestration surface. OAS Swarm Runner is the sole substrate; consumers drive swarm runs via OAS primitives directly. |
| Provider selection ownership | Improved | MASC persists `cascade_name` only; provider allowlists remain OAS-owned and legacy `allowed_providers` inputs are ignored |

## Boundary Audit Snapshot

| Module / Surface | Classification | Why |
|------------------|----------------|-----|
| `lib/oas_worker*.ml`, `lib/worker_oas.ml`, `lib/verifier_oas.ml` | Correct | OAS is consumed as the runtime contract; MASC chooses prompts, tools, policy, and verification usage |
| `lib/context_compact_oas.ml` | Acceptable but lossy | Runtime compaction delegates to OAS, but message-importance heuristics still depend on MASC text markers |
| `lib/memory_oas_bridge.ml` | Acceptable | Consumer-side adapter; imperative seeding removed in RFC-MASC-004 Phase 2, hook-first injection is now the sole path |
| `lib/keeper/keeper_agent_run.ml` + keeper checkpoint/context path | Boundary violation | Keeper still owns duplicate runtime state via `working_context` and relies on raw text markers such as `[STATE]` |

## Open Structural Gaps

- keeper runtime still uses a MASC-owned `working_context` wrapper around OAS context/checkpoint primitives
- keeper continuity still leaks domain semantics through raw message text (`[STATE]`, goal/memory markers)
- `memory_oas_bridge.ml` imperative seeding fully removed (RFC-MASC-004 Phase 2-3); hook-first is the sole path
- runtime-health signaling still relies on a narrow boolean `resource_check` callback instead of a structured probe
- proof-store and `oas-runtime` filesystem layout must stay behind thin adapters instead of being reconstructed ad hoc

## Delivery-Contract Split

- MASC owns the delivery contract itself: `contract_id`, acceptance checks, required artifacts, repair budget, evaluator role/cascade, proof/report surfaces.
- OAS should stay generic and receive only reusable harness/runtime primitives.
- Current local implementation keeps the contract in MASC coordination state (board posts, keeper FSM, governance queues) and feeds it into worker verification and proof artifacts without teaching OAS about MASC session semantics.

## Candidate Upstream Work

These are the next changes that are generic enough to propose upstream:

- harness case/result/verdict/repair-directive primitives that MASC evaluators can reuse
- richer swarm `agent_entry` metadata so `planned_worker` routing and telemetry survive end to end
- structured runtime-health probe callback to replace the current boolean `resource_check`

These stay in MASC:

- room/task/board/operator/governance semantics
- planner session policy and repair-budget policy
- proof/report JSON/markdown contracts and coordination-specific evidence rules

## Priority Order

1. **P1 — keeper runtime state ownership**
   - shrink the MASC-owned `working_context` role until OAS owns runtime context/checkpoint state
2. **P2 — marker/text leakage**
   - reduce dependence on raw `[STATE]`, `[GOAL]`, and memory-summary markers in runtime-facing paths
3. **P3 — team-session bridge fidelity** — Resolved (2026-04, team_session module purged; OAS Swarm Runner is sole substrate)
   - MASC team-session surface removed; coordination needs served via board posts + keeper FSM, swarm runs driven through OAS directly
4. **P4 — memory bridge hardening** — Resolved (2026-04-13, PR #6795 Phase 1 + Phase 2)
   - imperative seed/flush replaced by hook-first injection via `Memory_hooks` (RFC-MASC-004)
5. **P5 — doc truth alignment**
   - keep this contract, the implementation spec, and the utilization audit in sync

## What This Means Practically

- “Context integration in progress” now means **broader state unification**, not compaction.
- “Event_bus bridge planned” is no longer true for the current dashboard/SSE path.
- dashboard OAS runtime health should be read as **durable replay + live tail**, not as a live-only pulse.
- dashboard runtime `counts` should be read as **active truth**, while keeper inventory belongs to `configured_keepers`.
- “team_session pending migration” is no longer true; the `lib/team_session/` module has been **removed** — swarm runs go through OAS directly, coordination state lives in board posts and keeper FSM.

## Boundary Review Checklist

Use this checklist when reviewing boundary-touching PRs:

1. **OAS가 MASC를 새로 알게 되는가?**
   - generic runtime/harness primitive가 아니라 room/task/governance/session semantics가 OAS public contract로 새어 나오면 안 된다.
2. **MASC core가 provider/model 세부를 새로 배우는가?**
   - model ID, vendor, token/cost detail은 OAS-facing adapter/bridge에 머물러야 한다.
3. **문서 truth가 코드 truth와 일치하는가?**
   - 특히 cascade labels, runtime-health semantics, boundary-audit snapshot은 구현과 SSOT 문서가 함께 갱신되어야 한다.
4. **Checked-in cascade labels are explicit enough for stable review**
   - repository-default `config/cascade.json` entries should prefer explicit `provider:model_id` labels; runtime discovery/failsafe may still resolve local defaults elsewhere, but checked-in defaults should avoid ambiguous `provider:auto` labels.

## Boundary Rules for Future Work

1. If the problem is “single agent execution contract”, prefer fixing `oas_worker` / `worker_oas` / OAS-facing adapters.
2. If the problem is “room, board, governance, operator, workflow semantics”, keep it in MASC.
3. If a bridge is lossy, fix the MASC-side adapter first before proposing OAS API expansion.
4. Do not claim a subsystem is “migrated” if the runtime path works but key semantics are still dropped.

---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - lib/keeper/keeper_agent_run.ml
  - lib/cdal/proof_artifact_reader.ml
---

# External Agent Framework Patterns RFC

Status: draft
Updated: 2026-04-12

## Goal

Morph의 agent framework 비교 글을 출발점으로 삼되, `masc-mcp`에 바로 적용 가능한 패턴만 추려서
설계 우선순위와 landing point를 고정한다.

이 문서의 핵심 질문은 "어느 프레임워크로 갈아탈 것인가"가 아니라
"현재 `MASC -> OAS` spine 위에서 어떤 추상화를 제품 수준으로 끌어올릴 것인가"다.

## Scope

- 외부 패턴 비교:
  - LangGraph durable execution / replay
  - OpenAI Agents SDK workflow / guardrails / tracing
  - Google ADK + A2A Agent Card / discovery
  - Morph가 강조한 infra-first execution primitive 관점
- 내부 적용 축:
  - keeper checkpoint truth / replay
  - typed handoff / proof / verifier envelopes
  - infra primitive SSOT
  - A2A discovery consolidation

## Non-goals

- Claude Agent SDK, OpenAI Agents SDK, Google ADK, CrewAI, LangGraph를
  `masc-mcp` core runtime 위에 직접 embedding 하는 것
- role-play crew abstraction을 coordination core로 채택하는 것
- code-generating execution model을 keeper default로 바꾸는 것

## Decision Summary

1. `masc-mcp`는 orchestration/control plane으로 유지하고, single-agent runtime은 계속 OAS에 둔다.
2. 외부 비교에서 가장 먼저 가져올 패턴은 LangGraph류의 `checkpoint truth + replay discipline`이다.
3. 두 번째는 OpenAI Agents SDK가 보여주는 `typed workflow surface + guardrail/eval-friendly tracing`이다.
4. 세 번째는 Morph 글이 강조한 `framework보다 infra primitive가 중요하다`는 관점이다.
5. 네 번째는 Google ADK/A2A 쪽의 `Agent Card based discovery`를 remote interoperability 용도로 다듬는 것이다.

## Comparison

| External pattern | External claim | Current `masc-mcp` state | Decision |
|---|---|---|---|
| LangGraph durable execution | checkpoint, resume, replay/fork are first-class | keeper checkpoint는 실재하지만 truth/replay contract가 아직 분산됨 | adopt |
| OpenAI workflow primitives | handoff, guardrails, traces, evals are workflow-level building blocks | verification/proof/handoff는 있으나 envelope family가 분산됨 | adopt selectively |
| Google ADK + A2A | Agent Cards and protocol boundary for remote discovery | Agent Card/A2A surface는 이미 존재하나 canonical contract가 흩어져 있음 | adopt selectively |
| Morph infra-first view | orchestration보다 apply/search/sandbox/compaction primitive quality가 중요 | search/apply/sandbox/compaction이 각각 존재하지만 shared infra model이 없음 | adopt |
| CrewAI role-based crews | natural-language role composition | `masc-mcp`의 문제는 역할극보다 correctness / observability / state truth | reject for core |
| Smolagents code agent default | code generation drives tool invocation | keeper write path는 playground containment가 핵심 guardrail | reject for core |

## What to Keep

- `MASC`는 언제/왜/누가 실행되는지를 결정하고,
  `OAS`는 단일 agent runtime을 담당하는 현재 boundary를 유지한다.
- repo-local, single-machine, trusted-network coordination이라는 front-door promise를 유지한다.
- keeper playground containment를 sandbox SSOT로 유지한다.

## What to Change

### 1. Checkpoint Truth and Replay

Priority: P1

What to change:

- keeper continuity를 "same-trace continuity"가 아니라
  "checkpoint-backed replayable runtime state"로 더 엄격하게 정의한다.
- replay semantics를 문서에서 먼저 고정한다:
  - 무엇이 deterministic step인가
  - 어떤 side effect가 replay-safe 인가
  - 어떤 operation은 task boundary 뒤로 밀어야 하는가

Primary landing:

- `docs/spec/13-oas-integration.md`
- `docs/design/oas-masc-state-boundary.md`

Implementation anchors:

- `lib/keeper/keeper_checkpoint_store.ml`
- `lib/keeper/keeper_agent_run.ml`
- `lib/keeper/keeper_post_turn.ml`

Expected output:

- canonical checkpoint truth doc
- replay safety rules
- keeper read-path / checkpoint ownership cleanup backlog

### 2. Typed Handoff / Proof / Verifier Envelope

Priority: P2

What to change:

- `handoff_context`, proof bundle, verifier verdict, checkpoint evidence를
  하나의 typed envelope family로 정리한다.
- 지금처럼 각 subsystem이 비슷한 의미를 다른 JSON shape로 들고 있는 상태를 줄인다.

Primary landing:

- `docs/design/contract-driven-agent-loop-rfc.md`
- `docs/design/handoff-ssot-adr.md`
- `docs/design/proof-bundle-check-mapping.md`

Implementation anchors:

- `lib/tool_handover.ml`
- `lib/verification.ml`
- `lib/tool_verification.ml`
- `lib/cdal_loader.ml`
- `lib/cdal/proof_artifact_reader.ml`

Expected output:

- typed envelope vocabulary
- verifier/proof/handoff compatibility rules
- replayable evidence contract

### 3. Infra Primitive SSOT

Priority: P3

What to change:

- search, apply/write, sandbox, compaction을 "여러 기능"이 아니라
  shared execution primitive set으로 문서와 operator surface에서 묶는다.
- canonical primitive / compatibility-only primitive / experimental primitive를 구분한다.

Primary landing:

- `docs/COMMAND-PLANE-RUNBOOK.md`
- `docs/design/contract-driven-agent-loop-rfc.md`
- `docs/SEARCH-FABRIC-V1.md`

Implementation anchors:

- `lib/task_sandbox.ml`
- `lib/tool_compact.ml`
- `lib/context_compact_oas.ml`
- `lib/tool_code_write.ml`

Expected output:

- infra primitive inventory
- operator-facing composition rules
- canonical write/apply/search/sandbox language

### 4. A2A Discovery Consolidation

Priority: P4

What to change:

- current A2A/Agent Card surface를 유지하되,
  `local-only coordination`과 `remote discovery`를 구분해 contract를 정리한다.
- Agent Card는 capability discovery surface로만 유지하고,
  memory/tool/state internals를 노출하지 않는다는 원칙을 명문화한다.

Primary landing:

- `docs/SPEC.md`
- `docs/spec/09-server-transport.md`

Implementation anchors:

- `lib/agent_card.ml`
- `lib/a2a_tools.ml`
- `lib/server/server_routes_http_routes_frontend.ml`
- `lib/transport.ml`

Expected output:

- canonical Agent Card contract
- local vs remote discovery rules
- legacy compatibility boundary

## Sequenced Rollout

1. Checkpoint truth / replay RFC
2. Typed handoff / proof / verifier envelope RFC
3. Infra primitive SSOT cleanup
4. A2A discovery consolidation

Reason:

- 지금 코드베이스는 runtime truth가 가장 큰 structural risk다.
- envelope typing은 proof/verifier/handoff drift를 줄이는 두 번째 축이다.
- infra primitive는 이미 실체가 있으므로 naming + surface consolidation 성격이 강하다.
- A2A는 이미 동작하지만 front-door promise가 아니므로 마지막이 맞다.

## Explicit Rejections

- provider-native framework 전체를 `masc-mcp` core로 들여오지 않는다.
- LangGraph를 orchestration engine으로 통째로 바꾸지 않는다.
- CrewAI role-play abstraction을 keeper/team-session core로 채택하지 않는다.
- Smolagents식 code-exec-first runtime을 keeper default로 만들지 않는다.

## Evidence

- [근거] LangGraph durable execution / persistence / time-travel:
  https://docs.langchain.com/oss/python/langgraph/durable-execution ,
  https://docs.langchain.com/oss/python/langgraph/persistence ,
  https://docs.langchain.com/oss/python/langgraph/use-time-travel ;
  확인일시 2026-04-12 ; 신뢰도 High
- [근거] OpenAI Agents SDK / Agent Builder / trace grading / agent evals:
  https://platform.openai.com/docs/guides/agents-sdk/ ,
  https://platform.openai.com/docs/guides/agent-builder ,
  https://platform.openai.com/docs/guides/trace-grading ,
  https://platform.openai.com/docs/guides/agent-evals ;
  확인일시 2026-04-12 ; 신뢰도 High
- [근거] Google ADK + A2A:
  https://google.github.io/adk-docs/ ,
  https://google.github.io/adk-docs/a2a/intro/ ,
  https://google.github.io/adk-docs/a2a/ ;
  확인일시 2026-04-12 ; 신뢰도 High
- [근거] A2A specification / Agent Card discovery surface:
  https://a2aproject.github.io/A2A/specification/ ,
  https://github.com/a2aproject/A2A ;
  확인일시 2026-04-12 ; 신뢰도 High
- [근거] Morph framework comparison article:
  https://www.morphllm.com/ai-agent-framework ;
  확인일시 2026-04-12 ; 신뢰도 Medium

## Internal References

- `README.md`
- `docs/OAS-MASC-BOUNDARY.md`
- `docs/PRODUCT-REVIEW.md`
- `docs/KEEPER-CONTINUITY-VALIDATION.md`
- `docs/SEARCH-FABRIC-V1.md`

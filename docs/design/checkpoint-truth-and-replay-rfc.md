# Checkpoint Truth and Replay RFC

**Status**: Draft
**Date**: 2026-04-12
**Scope**: Keeper runtime checkpoint truth, replay semantics, side-effect boundary
**One sentence**: Productize keeper continuity as replayable checkpoint-backed runtime state with explicit side-effect boundaries, not as a vague same-trace memory story.

## Related Documents

- `../spec/13-oas-integration.md`
- `./checkpoint-truth-replay-implementation-checklist.md`
- `./oas-masc-state-boundary.md`
- `./delta-checkpoint-read-path.md`
- `./keeper-continuity-product-rfc.md`
- `../KEEPER-CONTINUITY-VALIDATION.md`

## Problem

현재 keeper continuity는 "same-trace continuity"라는 제품 언어는 있으나,
runtime 설계 차원에서 아래가 한 문서로 묶여 있지 않다.

- checkpoint의 SSOT가 무엇인가
- `resume`, `replay`, `fork`를 어떻게 구분하는가
- 어떤 step이 deterministic replay 대상인가
- 어떤 side effect는 replay-safe이고 어떤 것은 아닌가
- checkpoint truth와 domain truth가 충돌할 때 어느 쪽을 먼저 믿는가

이 공백 때문에 continuity, compaction, handoff, verifier, proof artifact가
각기 다른 의미로 "replay"를 말하게 된다.

## Goal

이 RFC는 keeper runtime에 대해 아래를 고정한다.

1. checkpoint truth hierarchy
2. replay semantics vocabulary
3. deterministic step boundary
4. side-effect classification
5. checkpoint write/load contract
6. rollout order

## Non-goals

- general long-term memory 설계
- cross-trace recall 설계
- verifier proof bundle 전면 개편
- OAS public API에 MASC domain semantics를 추가하는 것

## Terms

### Checkpoint truth

동일 `trace_id` 내에서 다음 turn을 재개하기 위해 필요한 runtime state의 canonical snapshot.

### Resume

현재 trace/session을 이어서 계속하는 것.
의도는 "이전 runtime state를 이어받아 다음 step으로 간다"이다.

### Replay

저장된 checkpoint를 기준점으로 다시 실행해 동일한 typed fact를 얻는 것.
목표는 "state reconstruction"이지 "동일한 raw token stream 재생"이 아니다.

### Fork

기존 checkpoint를 읽되, 원본 trace를 덮지 않고 다른 branch/trace로 분기해 실행하는 것.

### Side-effect boundary

replay 시 중복 실행이 허용되지 않는 작업이 시작되는 지점.

## Source of Truth Hierarchy

같은 keeper trace에 대해 충돌이 생기면 아래 순서로 truth를 본다.

1. **OAS checkpoint**
   - runtime messages
   - turn count
   - usage stats
   - lifecycle state
2. **Typed post-turn metadata derived from the checkpoint**
   - generation
   - compaction outcome
   - handoff outcome
   - continuity update timestamp
3. **Domain surfaces**
   - keeper meta summary
   - dashboard read models
   - continuity summary text

Rule:

- runtime reconstruction은 1번이 우선이다.
- operator diagnosis는 2번과 3번을 보조로 쓴다.
- 3번이 1번을 덮어쓰는 설계는 금지한다.

## Replay Semantics

### R1. Resume is the default continuity path

keeper continuity의 기본 경로는 `resume`이다.

- same `trace_id`
- same checkpoint lineage
- next turn continues from last saved checkpoint

이 경로는 continuity의 제품 contract와 directly 연결된다.

### R2. Replay is a diagnostic and validation path

`replay`는 operator / verifier / runtime diagnosis 경로다.

목적:

- checkpoint truth 검증
- deterministic typed fact 재생산
- continuity drift / artifact drift 분석

비목적:

- identical natural language regeneration
- exact same provider-side token stream 재현

### R3. Fork must not mutate the source lineage

`fork`는 source checkpoint를 읽을 수는 있지만,
원본 trace/session lineage를 덮어쓰면 안 된다.

## Deterministic Step Boundary

replay target은 "typed post-step facts"다.

아래는 replay 대상으로 본다.

- checkpoint load success/failure
- selected tool name
- tool input/output envelope shape
- mutation boundary reached 여부
- compaction decision
- handoff decision
- verifier verdict input/output envelope

아래는 replay 대상으로 보지 않는다.

- exact assistant wording
- exact provider internal retries
- exact hidden reasoning text
- exact token-by-token streaming sequence

## Side-effect Classes

### Class A: Pure runtime computation

Examples:

- prompt assembly
- context reduction
- tool selection
- typed verdict derivation

Replay rule:

- always replayable

### Class B: Read-only external observation

Examples:

- search
- status
- read-only board/task inspection
- checkpoint load

Replay rule:

- replayable if output is captured as typed evidence
- otherwise diagnostic replay only

### Class C: Idempotent domain mutation

Examples:

- duplicate-tolerant board/comment/vote style actions
- mutation with explicit dedupe key / commit token

Replay rule:

- replayable only through typed mutation evidence or dedupe token
- raw string inference from trace alone is insufficient

### Class D: Non-replay-safe external mutation

Examples:

- git push
- external API write
- deployment
- filesystem mutation outside a contained sandbox contract

Replay rule:

- do not auto-replay
- checkpoint may resume after the boundary, but diagnostic replay must treat this as a hard side-effect boundary

## Checkpoint Write / Load Contract

### Write contract

- post-turn checkpoint save happens after runtime state is normalized
- saved checkpoint must correspond to the continuity/read surfaces emitted for the same turn
- any sidecar or delta artifact is subordinate to the full checkpoint truth

### Load contract

- restore path loads native OAS checkpoint first
- fallback paths may exist for compatibility, but they must not redefine truth
- read surfaces that summarize continuity must clearly indicate when they are derived rather than directly restored

## Invariants

- **INV-OAS-CHK-001**: keeper runtime reconstruction starts from OAS checkpoint truth, not keeper summary text
- **INV-OAS-CHK-002**: replay judges typed facts, not exact model prose
- **INV-OAS-CHK-003**: class D side effects are never auto-replayed
- **INV-OAS-CHK-004**: fork never overwrites the source checkpoint lineage
- **INV-OAS-CHK-005**: domain read models may summarize checkpoint truth but may not supersede it

## Implementation Landing Points

Primary spec / contract:

- `docs/spec/13-oas-integration.md`
- `docs/design/oas-masc-state-boundary.md`

Primary code anchors:

- `lib/keeper/keeper_checkpoint_store.ml`
- `lib/keeper/keeper_agent_run.ml`
- `lib/keeper/keeper_post_turn.ml`

Secondary design touchpoints:

- `docs/design/delta-checkpoint-read-path.md`
- `docs/design/keeper-continuity-product-rfc.md`
- `docs/design/handoff-ssot-adr.md`

## Rollout Order

### Phase 1

- declare checkpoint truth hierarchy
- declare replay semantics vocabulary
- wire doc cross-references

### Phase 2

- reduce keeper-owned wrapper state around OAS checkpoint/context
- move replay-relevant state to typed post-turn facts

### Phase 3

- tighten side-effect classes and mutation boundary evidence
- make verifier/proof bundle consume the same replay vocabulary

### Phase 4

- optional delta checkpoint restore path, only after full-checkpoint truth is stable

## Open Questions

1. should replayable mutation evidence live with checkpoint metadata, proof bundle, or both?
2. which current continuity fields should be explicitly marked "derived, not canonical" on keeper status surfaces?
3. do we need a dedicated typed event for mutation boundary crossing, separate from raw trace/tool call logs?

## Evidence

- [근거] LangGraph durable execution / persistence / time-travel:
  https://docs.langchain.com/oss/python/langgraph/durable-execution ,
  https://docs.langchain.com/oss/python/langgraph/persistence ,
  https://docs.langchain.com/oss/python/langgraph/use-time-travel ;
  확인일시 2026-04-12 ; 신뢰도 High
- [근거] current MASC boundary state:
  `docs/OAS-MASC-BOUNDARY.md` ,
  `docs/spec/13-oas-integration.md` ;
  확인일시 2026-04-12 ; 신뢰도 High
- [근거] current keeper continuity product contract:
  `docs/design/keeper-continuity-product-rfc.md` ,
  `docs/KEEPER-CONTINUITY-VALIDATION.md` ;
  확인일시 2026-04-12 ; 신뢰도 High

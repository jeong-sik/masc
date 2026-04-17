---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_post_turn.ml
  - lib/keeper/keeper_rollover.ml
  - lib/keeper/keeper_agent_run.ml
  - lib/coord/coord_task.ml
  - specs/keeper-state-machine/KeeperGenerationLineage.tla
---

# ADR: Keeper Generation Lineage Parity

## Context

`generation`, `handoff`, `memory 기록시점`, dashboard 해석이 서로 다른 문서에서 다른 뜻으로 읽히고 있었다.
특히 generation을 child runtime처럼 읽을 여지가 있었지만, 현재 OCaml runtime truth는 그렇지 않다.

## Decision

### 1. Generation 의미

Generation은 **같은 keeper의 versioned self**다.

- handoff 성공 시 keeper identity는 유지된다.
- 대신 `trace_id`와 session 디렉터리가 교체된다.
- `generation`은 `+1` 된다.
- 이전 `trace_id`는 `trace_history`에 append-only로 누적된다.
- OAS는 checkpoint/session continuity truth를 담당하고, lineage manifest/index는 그 commit 이후 MASC가 append하는 telemetry다.

한 줄 요약: `same keeper, new trace`.

### 2. Parity-first 원칙

문서와 TLA+는 OCaml 구현을 설명하고 검증하는 역할만 한다.

- OCaml에 없는 lifecycle state를 product truth로 승격하지 않는다.
- generation을 child/offspring ontology로 확장하지 않는다.
- post-turn single-writer contract를 유지한다.

### 3. 기록시점 owner

| 경계 | owner | 저장소 |
|------|-------|--------|
| compaction / handoff / continuity | `keeper_post_turn` | checkpoint + keeper meta |
| memory bank | `keeper_agent_run` tail | `.masc/keepers/<name>.memory.jsonl` |
| episode | `keeper_agent_run` tail | `.masc/institution_episodes.jsonl` |
| hebbian | task lifecycle | `.masc/synapses/graph.json` |

### 4. Formal spec boundary

- `KeeperContextLifecycle.tla`는 context/checkpoint/compaction identity를 다룬다.
- `KeeperGenerationLineage.tla`는 handoff rollover의 `generation`, `trace_id`, `trace_history`, checkpoint parity를 다룬다.
- `KeeperStateMachine.tla`는 outer keeper phase truth를 계속 담당한다.

## Consequences

### Positive

- generation을 child runtime으로 오해하지 않게 된다.
- memory 기록시점과 lifecycle owner가 한 표로 닫힌다.
- TLA+ coverage가 compaction과 lineage로 분리되어 drift를 찾기 쉬워진다.

### Non-goals

- cross-generation 자유 recall 보장
- old/new generation 동시 실행
- constitution이나 core policy를 generation이 바꾸는 모델

## Defaults

- generation 초기값은 `0`
- lineage의 canonical surface는 `generation`, `trace_id`, `trace_history`
- identity 진화 논의가 다시 열리기 전까지, generation은 runtime child가 아니라 historical continuity unit으로 취급한다

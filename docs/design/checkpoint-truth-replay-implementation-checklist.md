---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_checkpoint_store.ml
  - lib/keeper/keeper_agent_run.ml
  - lib/keeper/keeper_post_turn.ml
---

# Checkpoint Truth and Replay Implementation Checklist

**Status**: Draft  
**Date**: 2026-04-12  
**Scope**: implementation checklist for the checkpoint truth / replay RFC

## Related

- `./checkpoint-truth-and-replay-rfc.md`
- `../spec/13-oas-integration.md`
- `./oas-masc-state-boundary.md`
- `./delta-checkpoint-read-path.md`

## Goal

`checkpoint truth and replay` RFC를 실제 코드 변경 단위로 쪼개어,
어느 모듈에서 무엇을 바꿔야 하는지와 검증 기준을 고정한다.

## Phase A. Truth Surface Cleanup

### A1. Declare native OAS checkpoint as runtime truth

- [ ] `lib/keeper/keeper_checkpoint_store.ml`
  - `save_oas` / `load_oas`를 runtime truth path로 유지
  - legacy checkpoint load path는 compatibility-only로 문서화
- [ ] `lib/keeper/keeper_agent_run.ml`
  - checkpoint load/write comments와 variable naming이 truth hierarchy와 일치하는지 정리
- [ ] `lib/keeper/keeper_post_turn.ml`
  - post-turn lifecycle가 `Agent_sdk.Checkpoint.t`를 canonical input/output으로 취급하는지 확인

Acceptance:

- restore path 설명에서 native OAS checkpoint가 먼저 나온다
- legacy path는 fallback 또는 migration wording만 가진다

### A2. Mark derived read surfaces explicitly

- [ ] keeper status / continuity 관련 read surface 문서에서
  `continuity_summary`, `generation`, `last_continuity_update_ts` 중
  derived field를 명시
- [ ] `docs/KEEPER-CONTINUITY-VALIDATION.md`와 wording 일치

Acceptance:

- operator 문서에서 canonical vs derived distinction이 보인다

## Phase B. Replay Semantics and Boundary

### B1. Mutation boundary evidence normalization

- [ ] `lib/keeper/keeper_agent_run.ml`
  - committed tool 이후 mutation boundary를 typed event/fact로 다룰 수 있는지 점검
  - 현재 string sentinel에 의존하는 부분을 inventory
- [ ] `lib/keeper/keeper_post_turn.ml`
  - compaction / handoff / overflow retry가 replay target typed fact로 충분한지 점검

Acceptance:

- replay target facts 목록이 코드와 문서에서 일치한다
- mutation boundary가 raw prose가 아니라 typed outcome로 설명된다

### B2. Side-effect class mapping

- [ ] current keeper tools를 RFC의 class A/B/C/D에 임시 매핑
- [ ] Class D replay 금지 규칙이
  `keeper_bash`, PR submit, external writes 쪽과 모순 없는지 확인

Implementation anchors:

- `lib/keeper/keeper_agent_run.ml`
- `lib/keeper/keeper_exec_shell.ml`
- `lib/tool_code_write.ml`

Acceptance:

- non-replay-safe mutation examples가 실제 write gate와 충돌하지 않는다

## Phase C. Wrapper Reduction

### C1. `working_context` dependency inventory

- [ ] `lib/keeper/keeper_exec_context.ml`
  - `working_context`가 어디서 필요한지 inventory 작성
- [ ] `lib/keeper/keeper_post_turn.ml`
  - `context_of_oas_checkpoint` 결과를 다시 wrapper로 다루는 지점 정리
- [ ] `lib/keeper/keeper_agent_run.ml`
  - checkpoint load 후 wrapper가 필요한 이유를 분리

Acceptance:

- wrapper가 truly required인 필드와 historical residue를 구분한 inventory가 있다

### C2. Marker leakage inventory

- [ ] `[STATE]`, `[GOAL]`, memory-summary marker read/write path 수집
- [ ] checkpoint patching이 marker-preserving trick인지, typed state transport인지 구분

Implementation anchors:

- `lib/keeper/keeper_agent_run.ml`
- `lib/context_compact_oas.ml`
- `lib/keeper/keeper_post_turn.ml`

Acceptance:

- marker leakage 제거 backlog가 독립 작업 항목으로 분리된다

## Phase D. Optional Delta Path

### D1. Delta restore stays subordinate

- [ ] `docs/design/delta-checkpoint-read-path.md`
  - delta는 full checkpoint subordinate임을 계속 유지
- [ ] restore ordering이 RFC wording과 일치하는지 확인

Acceptance:

- delta path는 optimization이지 truth source가 아님이 명시된다

## Code Anchors

### Primary

- `lib/keeper/keeper_checkpoint_store.ml`
- `lib/keeper/keeper_agent_run.ml`
- `lib/keeper/keeper_post_turn.ml`
- `lib/keeper/keeper_exec_context.ml`

### Secondary

- `lib/keeper/keeper_exec_shell.ml`
- `lib/tool_code_write.ml`
- `lib/context_compact_oas.ml`

## Validation Checklist

- [ ] `docs/spec/13-oas-integration.md` open ledger reflects the same phases
- [ ] `docs/design/checkpoint-truth-and-replay-rfc.md` terminology matches implementation checklist
- [ ] continuity product RFC does not over-promise beyond replay truth
- [ ] no code path is described as replay-safe if the current write gate treats it as unsafe

## Deferred Until After Phase A-C

- delta restore implementation
- generalized time-travel / fork UX
- proof-bundle level replayable mutation evidence v2

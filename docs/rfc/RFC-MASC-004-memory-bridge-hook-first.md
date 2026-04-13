# RFC-MASC-004: Memory Bridge Hook-First Migration

**Status**: Draft
**Date**: 2026-04-13
**Scope**: `lib/memory_oas_bridge.ml`, `lib/keeper/keeper_agent_run.ml`
**One sentence**: `memory_oas_bridge.ml`의 imperative seeding 5개 함수를 OAS `BeforeTurnParams` hook 경유로 전환하여 MASC↔OAS 경계 violation을 제거하고, keeper_agent_run.ml의 명시적 호출 의존성을 끊는다.

## Related Documents

- `lib/memory_oas_bridge.ml` (679줄) — 현재 imperative seeding/flushing 어댑터
- `lib/keeper/keeper_agent_run.ml` (~line 1385, ~1518) — seeding/flushing call site
- `docs/OAS-MASC-BOUNDARY.md` (lines 68, 72-78) — "Acceptable but lossy" 평가, P4 우선순위
- OAS `lib/hooks.mli` — `BeforeTurnParams`, `AfterTurn` hook events
- OAS `lib/context.ml` — Context.t, context injection pipeline
- `feedback_use-oas-context-injector.md` — OAS context_injector 파이프라인 사용 필수
- `feedback_no-lifecycle-invasion-from-masc.md` — OAS lifecycle 재구현 금지
- RFC-MASC-001 — Keeper Checkpoint Boundary Migration (선행 권장이나 병행 가능)

## Problem Statement

### 현재 구조: Imperative Seeding

```
keeper_agent_run.ml (line ~1385)
  └── memory_oas_bridge.create_memory_full()
        ├── seed_episodes()        → OAS Episodic tier에 직접 push
        ├── seed_procedures_as_oas() → OAS Procedural tier에 직접 push
        ├── seed_institution()     → Long_term에 JSON 직접 저장
        └── (optional) seed_all_procedures_as_oas()

keeper_agent_run.ml (line ~1518, turn 종료 후)
  └── memory_oas_bridge.flush_all()
        ├── flush episodes → JSONL
        └── flush procedures → JSONL
```

문제:

1. **OAS lifecycle invasion**: MASC가 OAS의 context/memory를 직접 조작한다. OAS 관점에서 이 seeding은 "외부에서 나도 모르게 context가 변경되는" 상황.
2. **Hook 우회**: OAS는 `BeforeTurnParams`에서 context injection을 제공한다. MASC가 이를 무시하고 직접 push하면 OAS의 context flow invariant가 깨짐.
3. **순서 의존성**: `create_memory_full()`이 `Agent.run()` 직전에 호출되어야 한다. 호출 순서가 바뀌면 silent failure.
4. **테스트 불가**: imperative seeding은 OAS agent 테스트에서 mock하기 어려움. Hook이면 OAS harness에서 자연스럽게 테스트 가능.
5. **Flushing 누락 위험**: agent가 crash로 종료하면 `flush_all()`이 호출되지 않아 memory 유실.

### Boundary Violation 카운트

`docs/OAS-MASC-BOUNDARY.md` 기준:
- Memory bridge imperative seeding → **P4** (현재)
- 이 RFC 완료 후 → P4 해소, violation count -1

## Design

### Principle: Hook-Mediated, Not Direct-Push

MASC는 OAS hook을 통해 memory를 주입한다. OAS가 제공하는 `BeforeTurnParams` hook에서 context를 조정하고, `AfterTurn` hook에서 flush를 수행한다.

### Architecture: Before vs After

```
[현재] MASC → direct push → OAS memory tiers
[목표] MASC → hook registration → OAS invokes hook → MASC provides memory
```

### Part A: Hook Registration

keeper가 OAS agent를 생성할 때 hook을 등록한다.

**OAS Hook API 실측 결과 (2026-04-13)**: `BeforeTurnParams` hook은 `AdjustParams of turn_params`만 반환 가능. `Context.inject_memory` 같은 tier 직접 조작 API는 존재하지 않음. 유일한 injection point는 `turn_params.extra_system_context: string option`. 따라서 memory를 텍스트로 직렬화하여 system context에 주입하는 방식을 사용한다.

```ocaml
(* memory_hooks.ml — 신규 모듈, 102줄 *)

let render_memory_context ~bridge =
  let episodes = Memory_oas_bridge.load_episodes_text bridge in
  let procedures = Memory_oas_bridge.load_procedures_text bridge in
  let institution = Memory_oas_bridge.load_institution_text bridge in
  String.concat "\n" [episodes; procedures; institution]

let make ~bridge =
  let before_turn_params _event =
    let memory_text = render_memory_context ~bridge in
    AdjustParams { extra_system_context = Some memory_text }
  in
  let after_turn _event =
    Memory_oas_bridge.flush_incremental bridge;
    Continue
  in
  { before_turn_params; after_turn }
```

**한계**: memory가 구조화된 tier(Episodic/Procedural)가 아닌 plain text로 주입되므로 OAS의 memory retrieval 기능(예: 관련성 기반 episode 선택)을 활용하지 못한다. 장기적으로 OAS에 `BeforeTurnParams`에서 Memory.t tier를 조작하는 API를 추가하는 것이 바람직하다.

### Part B: memory_oas_bridge.ml 리팩토링

현재 679줄의 `memory_oas_bridge.ml`에서:

| 현재 함수 | 전환 후 | 호출 주체 |
|-----------|---------|----------|
| `create_memory_full` | 삭제. 개별 load 함수로 분해 | OAS hook |
| `seed_episodes` | `load_episodes` (순수 읽기, push 없음) | OAS hook |
| `seed_procedures_as_oas` | `load_procedures` (순수 읽기) | OAS hook |
| `seed_institution` | `load_institution` (순수 읽기) | OAS hook |
| `flush_all` | `flush_incremental` (turn 단위) | OAS hook |
| 캐시 로직 (file_stamp) | 유지. 내부 최적화 | 변경 없음 |

핵심 변경: **push 함수(side effect) → load 함수(pure read) + OAS가 주입**.

### Part C: Flush 안전성 개선

현재 `flush_all()`은 agent 종료 후 1회 호출. Crash 시 유실.

Hook-first 전환 후:
- `AfterTurn` hook에서 **매 turn 종료마다** incremental flush
- OAS의 `Eio.Switch.on_release`에서 final flush (crash safety)
- JSONL append-only이므로 중복 flush는 idempotent

### Part D: Migration Path

```
Phase 1: Hook adapter 추가 (기존 imperative 경로와 병행)
  ├── memory_hooks.ml 생성
  ├── keeper_hooks_oas.ml에 memory hook 등록
  └── 기존 create_memory_full/flush_all 유지 (fallback)

Phase 2: 기존 imperative 경로 제거
  ├── keeper_agent_run.ml에서 create_memory_full 호출 삭제
  ├── keeper_agent_run.ml에서 flush_all 호출 삭제
  └── memory_oas_bridge.ml에서 seed_* 함수 deprecate

Phase 3: Dead code 정리
  ├── seed_episodes, seed_procedures_as_oas, seed_institution 삭제
  ├── create_memory_full 삭제
  └── flush_all → flush_incremental로 완전 전환
```

## Verification

### 완료 기준

```bash
# 1. Imperative seeding call site 제거 확인
rg 'create_memory_full\|seed_episodes\|seed_procedures_as_oas\|seed_institution' lib/keeper/ | wc -l
# Expected: 0

# 2. flush_all call site 제거 확인
rg 'flush_all' lib/keeper/ | wc -l
# Expected: 0

# 3. Hook registration 확인
rg 'memory_hooks\|before_turn_params.*memory\|after_turn.*flush' lib/keeper/ | wc -l
# Expected: >= 2

# 4. OAS-MASC-BOUNDARY.md 업데이트
rg 'Imperative seeding' docs/OAS-MASC-BOUNDARY.md
# Expected: "Resolved" 또는 해당 항목 제거
```

### 테스트

- Unit test: `load_episodes`/`load_procedures` 순수성 검증 (side effect 없음)
- Integration test: mock OAS agent에 memory hook 등록 → turn 실행 → memory 주입 확인
- Crash test: agent turn 중 cancel → JSONL에 이전 turn 데이터 보존 확인
- Regression: 기존 keeper 시나리오에서 memory 정확도 동등성 확인

## Implementation Phases

### Phase 1: Hook Adapter (병행 운영, 1 PR)
- `memory_hooks.ml` 생성 (hook registration)
- `memory_oas_bridge.ml`에 `load_*` pure read 함수 추가
- `keeper_hooks_oas.ml`에서 hook 등록 통합
- Feature flag: `MASC_MEMORY_HOOK_FIRST=true` (기본 false)

### Phase 2: Imperative 경로 제거 (1 PR)
- `MASC_MEMORY_HOOK_FIRST` 기본 true
- `keeper_agent_run.ml`에서 `create_memory_full`/`flush_all` 호출 제거
- `docs/OAS-MASC-BOUNDARY.md` P4 항목 업데이트

### Phase 3: Dead Code 정리 (1 PR)
- `MASC_MEMORY_HOOK_FIRST` flag 제거
- `seed_*` 함수 삭제, `create_memory_full` 삭제
- `memory_oas_bridge.ml` 크기 목표: 679줄 → ~400줄

## Risks

| Risk | Mitigation |
|------|------------|
| Hook 순서가 memory seeding 시점과 맞지 않음 | Phase 1에서 trace-level 검증 필수: (1) `BeforeTurnParams` hook이 context 구성 이전/이후 어느 시점에 호출되는지 OAS 코드에서 확인, (2) hook에서 주입한 memory가 downstream hook(safety filter 등)에 보이는지 확인. 동등성이 증명되지 않으면 OAS에 hook 순서 보장 API 요청 |
| Incremental flush가 JSONL 파일을 과도하게 open/close | Append-only + buffered write. 매 turn이 아닌 dirty flag 기반 |
| RFC-MASC-001과의 충돌 | MASC-001은 working_context/[STATE] 경계, 이 RFC는 memory bridge. 파일 겹침은 `keeper_agent_run.ml`만. 병행 가능하되 merge 순서 주의 |
| 캐시 무효화 로직이 hook context에서 동작하지 않음 | file_stamp 로직은 memory_oas_bridge 내부. hook은 load 결과만 소비하므로 캐시는 투명 |

## Scope Exclusion

- OAS hooks.ml 변경 (OAS 측 hook은 이미 충분)
- working_context 제거 (RFC-MASC-001 범위)
- [STATE] text marker 제거 (RFC-MASC-001 범위)
- 5-tier memory 모델 자체의 재설계 (Long_term/Episodic/Procedural 구조 유지)
- PG backend 추가 (filesystem-first 원칙 유지)

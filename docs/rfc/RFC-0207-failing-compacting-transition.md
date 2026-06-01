# RFC-0207: Failing → Compacting 전이 허용

- Status: Draft
- Date: 2026-06-01
- Area: lib/keeper/ (keeper lifecycle FSM)
- Builds on: keeper_state_machine_types `can_transition`, keeper_state_machine `derive_phase`

## 1. 동기

Keeper `garnet`에서 다음 에러 체인이 반복 발생:

```
[WARN] registry: dispatch_event rejected error=invalid_transition: failing -> compacting
       (event compaction_started caused derive_phase to produce compacting from failing,
        but this transition is not in the matrix)
[ERROR] keeper cycle exception: validate_compaction_transition:
        invalid compaction transition Compaction_accumulating -> Compaction_done
```

### 근본 원인

`can_transition` 매트릭스와 `derive_phase` priority ordering 간 불일치:

| 함수 | 규칙 | 결과 |
|------|------|------|
| `derive_phase` | priority 8 (`compaction_active`) > priority 9 (`not heartbeat_healthy`) | `Failing`에서 `Compacting` 반환 가능 |
| `can_transition` | `Failing → Compacting` 명시적 거부 | `Error Invalid_transition` |

`can_transition` 매트릭스 (`keeper_state_machine_types.ml:340-343`):
```ocaml
| Failing, (Running | Overflowed | Crashed | Draining | Paused) -> true
| ( Failing
  , (Offline | Failing | Compacting | HandingOff | Stopped | Restarting) ) ->
  false
```

`derive_phase` priority (`keeper_state_machine.ml:77-146`):
```
priority 6: guardrail_triggered         → Failing   (beats compaction)
priority 8: compaction_active           → Compacting (beats priority 9)
priority 9: not heartbeat_healthy etc.  → Failing   (loses to compaction)
```

### 에러 전파 체인

1. Keeper가 `Failing` 상태 (heartbeat/turn health degradation, priority 9)
2. Compaction harness 실행 (정상 완료, `saved_tokens` 보고)
3. `compaction_started` 이벤트 dispatch → `Failing → Compacting` 전이 거부
4. Compaction sub-FSM이 `Compaction_accumulating`에서 `Compaction_done`으로 바로 이동 시도 → `compacting` 중간 단계 누락 → spec violation

## 2. 제안

### 2.1 `can_transition` 매트릭스에 `Failing → Compacting` 추가

```ocaml
(* Before *)
| Failing, (Running | Overflowed | Crashed | Draining | Paused) -> true
| ( Failing
  , (Offline | Failing | Compacting | HandingOff | Stopped | Restarting) ) ->
  false

(* After *)
| Failing, (Running | Overflowed | Compacting | Crashed | Draining | Paused) -> true
  (* via derive_phase priority 8: compaction_active beats priority 9 health
     degradation.  Compaction is an independent maintenance operation that can
     proceed during health degradation and may help recovery. *)
| ( Failing
  , (Offline | Failing | HandingOff | Stopped | Restarting) ) ->
  false
```

### 2.2 의미적 타당성

- Compaction은 context 압축이라는 독립적인 유지보수 작업
- Health degradation(heartbeat/turn 불량)과 context overflow는 직교하는 관심사
- Compaction이 health recovery에 도움이 될 수 있음 (context 공간 확보)
- `Compacting → Failing`은 이미 허용됨 (line 360)
- 양방향 전이가 가능해야 FSM이 일관됨

### 2.3 guardrail_triggered는 영향 없음

`derive_phase`에서 `guardrail_triggered` (priority 6)가 `compaction_active` (priority 8)보다 높으므로, guardrail이 트리거된 상태에서는 compaction이 시작되지 않음. 이 전이는 heartbeat/turn health degradation (priority 9)에서만 발생.

## 3. 영향 범위

| 파일 | 변경 |
|------|------|
| `lib/keeper/keeper_state_machine_types.ml` | `can_transition` 매트릭스 1행 수정 |
| `lib/keeper/keeper_state_machine_phase.ml` | Mermaid diagram 동기화 |
| `test/test_keeper_lifecycle_*.ml` | `Failing → Compacting` 전이 테스트 추가 |

## 4. 검증

1. `dune build @check` — exhaustive match가 새 전이를 인식
2. Keeper cycle exception 재현 시나리오에서 WARN/ERROR 소멸 확인
3. TLA+ 모델에서 safety invariant 유지 확인

## 5. 위험

- **낮음**: `derive_phase`가 이미 이 전이를 암시적으로 허용하고 있었으므로, 매트릭스를 맞추는 것은 버그 수정에 가까움
- Compaction이 `Failing` 상태의 keeper에 영향을 미칠 수 있지만, `Compacting → Failing` 역전이도 허용되므로 FSM은 자가복구 가능

---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_composite_observer.ml
  - lib/keeper/keeper_unified_turn.ml
  - lib/keeper/keeper_registry.ml
---

# RFC-0003 Phase 2: Turn-Scoped Observation Lifecycle

**Status**: Draft
**Date**: 2026-04-14
**Scope**: `masc-mcp` composite observer mutation model + snapshot schema
**One sentence**: Decision/Cascade sub-FSM의 live state를 관찰하기 위한 mutation 모델 결정 — single-writer invariant를 깨지 않으면서 stale state도 만들지 않는 설계.

## Related Documents

- `RFC-0003-keeper-composite-lifecycle.md` — composite observer 도입 (Phase 0)
- Issue #7122 — sub-FSM derivation 결함 분석
- PR #7126 — Phase 1: turn-scoped `current_turn_observation` (anti-stale barrier)
- `lib/keeper/keeper_composite_observer.ml` — observer 구현
- `lib/keeper/keeper_registry.ml` — single writer (registry single-writer invariant)
- `specs/keeper-state-machine/KeeperCompositeLifecycle.tla` — joint invariants

## 1. Context

Phase 1 (#7126)이 `current_turn_observation : turn_observation option` 필드를 도입해 **anti-stale barrier**를 확립했다. 이후 runtime write point가 추가되면서 현재 KTC live domain은 다음과 같이 닫혀 있다:

| Sub-FSM | 현재 runtime variant |
|---------|----------------------|
| `decision_stage` | `Undecided`, `Guard_ok`, `Gate_rejected`, `Tool_policy_selected` |
| `cascade_state` | `Idle`, `Selecting`, `Trying`, `Done`, `Exhausted` |
| `turn_phase` | `Idle`, `Prompting`, `Executing`, `Compacting`, `Finalizing` |

따라서 남은 과제는 "variant를 더 만들기"가 아니라, 이 runtime 3축 contract를 `KeeperTurnCycle.tla`와 1:1로 정렬하고 overflow retry 같은 모호한 edge를 선명하게 만드는 것이다.

Phase 2의 목표는 이 갭을 메우되 **세 가지 invariant**를 모두 보존하는 것:
1. **Single-writer**: `registry_entry`는 단일 writer (`keeper_unified_turn` 호출 경로)만 변경
2. **Anti-stale**: idle keeper의 snapshot에 stale `Done`/`Guard_ok` 등이 남지 않음
3. **Pure projection**: observer는 read-only (mutation은 writer에 위임)

## 2. Decision: Mutation 모델

3가지 후보를 비교한다.

### 2.1 후보 A1: Background fiber subscriber

**구조**:
- Turn 시작 시 Eio fiber spawn — `Event_bus.subscribe ~filter:(filter_agent meta.name)`
- Loop: `Event_bus.drain sub` → 수신된 payload별로 `current_turn_observation` mutate
- Turn 종료 시 fiber cancel + unsubscribe

**장점**:
- Live update — `Prompting`/`ToolCall`이 OAS 이벤트와 동시에 dashboard에 반영
- Observer는 read-only, pure projection 유지

**단점 (rejected 사유)**:
- **Two writers race**: background fiber와 `mark_turn_finished` 사이 race condition. 이벤트 도착이 finished 호출 후에 와도 fiber가 cancel 전이면 stale write 발생
- Eio fiber lifecycle 복잡도: `Switch.run` 안에서 spawn해야 하고, cancellation 시점이 정확해야 함
- Mutex 보호 필요: `update_entry`가 atomic이지만, "drain → 변환 → write"가 atomic하지 않음
- 디버깅 난이도 증가: race condition은 재현 어려움

### 2.2 후보 A2: Observer-time drain

**구조**:
- `observe()` 호출 시점에 drain + `current_turn_observation` mutate

**단점 (rejected 사유)**:
- **Pure projection 위반**: observer는 정의상 read-only. 호출만으로 state가 바뀌면 idempotency 깨짐
- 동일 entry를 두 번 observe하면 다른 결과 — dashboard에서 race 가능
- "관찰 행위가 관찰 대상을 바꾼다" — Heisenberg 효과

### 2.3 후보 A3: Live (current) vs Snapshot (last_completed) 분리 [권장]

**구조**:
- `current_turn_observation : turn_observation option` — **live**, single writer (`keeper_unified_turn`)
- `last_completed_turn : completed_turn_observation option` — turn 종료 시 freeze된 결과
- Observer는 둘 다 read-only
- Snapshot에 `is_live: bool` 명시 (`current` Some이면 true)

**`mark_turn_finished` semantic**:
```ocaml
(* Phase 1: clear *)
{ e with current_turn_observation = None }

(* Phase 2: move *)
{ e with
  current_turn_observation = None;
  last_completed_turn = Some (freeze e.current_turn_observation) }
```

**Observer derivation**:
- Live state (`Prompting`/`Executing`/`ToolCall`/`Selecting`/`Trying`): `current_turn_observation`만 사용. None이면 idle 표시.
- Terminal state (`Done`/`Exhausted`/`Guard_ok`/`Gate_rejected`/`Tool_policy_selected`): `last_completed_turn`만 사용. **Snapshot의 별도 필드** (`last_outcome`)로 노출, sub-FSM state와 분리.

**장점**:
- Single-writer 보존
- Anti-stale: idle keeper의 sub-FSM은 모두 Idle/Undecided. Terminal 정보는 별도 필드(`last_outcome`)로 명시적
- Pure projection 유지
- Dashboard에서 "현재 진행 중" vs "직전 결과"를 시각적으로 분리 가능

**단점**:
- Live state 세분화(`Prompting`/`ToolCall`/`Selecting`/`Trying`)는 Phase 3까지 미루어짐
- Phase 2에서는 `Executing` 1개만 live로 도달

**Phase 3 (선택 follow-up)**: 세분화가 정말 필요하면 A1을 mutex 보호로 추가. A3 위에 stack하면 안전. (A1만 단독 도입은 race 위험)

## 3. Schema 변경 (A3)

### 3.1 Registry

`lib/keeper/keeper_registry.mli`:
```ocaml
type completed_turn_observation = {
  turn_id : int;
  started_at : float;
  ended_at : float;
  outcome : [
    | `Ok of { selected_model : string option; fallback_applied : bool }
    | `Failed of { reason : string }
    | `Cancelled
  ];
  guard_passed : bool;  (* derived from auto_rules.guardrail_stop *)
}

type registry_entry = {
  ...
  current_turn_observation : turn_observation option;     (* live *)
  last_completed_turn : completed_turn_observation option; (* freeze *)
}
```

### 3.2 Composite Observer Snapshot

`lib/keeper/keeper_composite_observer.mli`:
```ocaml
type snapshot = {
  ...
  is_live : bool;  (* current_turn_observation = Some *)
  last_outcome : last_outcome option;  (* from last_completed_turn *)
}

and last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_outcome : [`Guard_ok | `Gate_rejected | `Tool_policy_selected] option;
  cascade_outcome : [`Done | `Exhausted] option;
  selected_model : string option;
}
```

`derive_*` 함수 변경:
- `derive_turn_phase`: `current_turn_observation`만 (Phase 1 그대로)
- `derive_decision_stage`: `current_turn_observation`이 None이면 `Undecided`, Some이면 (Track B의 audit 조회로 `Guard_ok` 도달 가능)
- `derive_cascade_state`: `current_turn_observation`이 None이면 `Idle`. (Phase 2에서는 `Executing`까지만 도달, Phase 3에서 세분화)

### 3.3 JSON Output

```json
{
  "is_live": true,
  "ksm_phase": "running",
  "ktc_turn_phase": "executing",
  "kdp_decision": "guard_ok",
  "kcl_cascade_state": "idle",
  "last_outcome": {
    "turn_id": 42,
    "ended_at": 1745234567.123,
    "decision_outcome": "guard_ok",
    "cascade_outcome": "done",
    "selected_model": "qwen3.5-35b"
  }
}
```

### 3.4 Dashboard FSM Hub

- `is_live = true`: 현재 sub-FSM state를 live indicator(녹색 점)와 함께 표시
- `is_live = false`: sub-FSM state는 idle. `last_outcome` 패널을 별도로 "직전 turn 결과"로 표시
- Stale 여부가 시각적으로 명확

## 4. TLA+ Spec 정합성

`KeeperCompositeLifecycle.tla` (PR #7038)와의 관계:

- Phase 1의 `current_turn_observation`은 **TLA+ spec에 명시되지 않은 implementation detail** — spec은 sub-FSM state의 join action만 정의. Observation lifecycle은 implementation 영역.
- `is_live` flag는 TLA+ state variable과 직접 매핑되지 않음. "관측 시점에 turn이 진행 중인가"는 spec의 abstraction level 위.
- `last_completed_turn`은 spec의 history variable과 유사 — 과거 state의 freeze. Spec에 명시할 필요 없음.

**결론**: A3는 TLA+ spec과 무관 (orthogonal). Spec은 join action / safety invariant만 다루고, observation lifecycle은 implementation contract.

## 5. Acceptance Criteria

- [ ] Mutation 모델 A3 채택 + A1/A2 rejected 근거 명시 (이 RFC가 충족)
- [ ] Single-writer invariant 분석 — `keeper_unified_turn`만 `current_turn_observation`/`last_completed_turn` 변경
- [ ] Anti-stale barrier 보존 — idle snapshot에 stale sub-FSM 없음 (별도 `last_outcome` 필드)
- [ ] Pure projection 유지 — `observe()` mutation 없음
- [ ] Snapshot schema 변경: `is_live: bool`, `last_outcome: last_outcome option`
- [ ] Phase 3(live 세분화)는 별도 RFC + A1을 mutex 보호로 stacking

## 6. Non-goals

- Live `Prompting`/`ToolCall`/`Selecting`/`Trying` 세분화 — Phase 3 (선택)
- Background fiber subscriber 도입 — Phase 3 (옵션)
- TLA+ spec 변경 — orthogonal
- Dashboard UI 재설계 — `is_live` indicator 추가만 (기존 컴포넌트 수정 최소)

## 7. Implementation Plan

1. **Track A (이 RFC)** — design 문서 (현재 PR)
2. **Track B (병렬)** — `latest_decision_outcome` accessor (decision_audit) + observer 사용. **Phase 2 구현 후에야 실제로 의미 있는 값이 노출됨.** 따라서 Track B는 stub만 추가하거나 Phase 2 merge 후 wiring.
3. **Track C (이 RFC merge 후)** — A3 schema 구현:
   - Registry: `last_completed_turn` 필드 + setter
   - `mark_turn_finished` semantic 변경
   - Observer: `is_live`/`last_outcome` snapshot 필드
   - Test: stale 비지속 + last_outcome 정확성

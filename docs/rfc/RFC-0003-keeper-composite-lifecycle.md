# RFC-0003: Keeper Composite Lifecycle Observer

**Status**: Draft
**Date**: 2026-04-14
**Scope**: `masc-mcp` cross-spec joint invariants + dashboard observer contract
**One sentence**: Decision/Cascade/Memory/Compaction/Recovery의 turn 단위 상호작용을 1급으로 관찰하기 위한 composition observer를 도입하고, 기존 3개의 부분 합성 spec이 커버하지 못하는 joint invariants + `state-fsm-gap-2026-04-13.md` P4(RecoveryOrchestration)를 한 spec에 흡수한다.

## Related Documents

- `RFC-0001-det-nondet-boundary-harness.md` — Det/NonDet 경계 원칙
- `RFC-0002-keeper-state-machine.md` — 11-state parent phase FSM (이 RFC는 transition을 추가하지 않는다)
- `docs/tla-audit/state-fsm-gap-2026-04-13.md` — Bug #1, 제안 P1~P5 (여기서 P4를 흡수)
- `docs/tla-audit/cascade-fsm-gap-2026-04-13.md`
- `docs/tla-audit/decision-fsm-gap-2026-04-13.md`
- `docs/design/oas-masc-state-boundary.md` — MASC/OAS SSOT
- `specs/keeper-state-machine/KeeperStateMachine.tla` — 11-state spec
- `specs/keeper-state-machine/KeeperCoreTriad.tla` — State × Decision × Cascade (5-phase 투사)
- `specs/state-product/StateProduct.tla` — Keeper × Turn × Validation 직교 합성
- `specs/keeper-state-machine/KeeperContextLifecycle.tla` — Context + Compaction + Checkpoint
- `specs/bug-models/MemoryCompaction.tla`, `CascadeLiveness.tla`

## 1. Context & Motivation

`masc-mcp` 저장소는 이미 세 개의 부분 합성 spec을 가진다.

| Spec | 합성 축 | 커버 | 미커버 |
|------|---------|------|--------|
| `KeeperCoreTriad.tla` | State × Decision × Cascade | cascade routing, capability gate, side-effect containment | Memory compaction, turn cycle, recovery orchestration, 11-state 전체 |
| `StateProduct.tla` | Keeper × Turn × Validation | det/nondet boundary per turn | Decision pipeline, Cascade, Memory |
| `KeeperContextLifecycle.tla` | Context + Compaction + Checkpoint | context identity on resume, tool pair integrity | State machine의 11-state, Cascade, Decision |

세 spec은 각자 영역에서 유효하지만, **한 turn 안에서 여러 FSM이 순서를 지키며 전이하는 joint property**는 아무도 검사하지 않는다. 근거:

- `Keeper_state_machine.mli:131-136` `Context_measured` 이벤트는 Decision, Compaction, Cascade, Recovery의 분기 조건을 공통으로 공급하지만 이 공유 측정의 존재를 joint spec으로 명시한 곳이 없다.
- `keeper_post_turn.ml:45-232` `apply_post_turn_lifecycle`는 `Compaction_started/completed`, `Handoff_started/completed`를 한 turn 안에 atomic하게 emit하지만, 이 atomic 경계를 TLC로 검증할 수 있는 spec이 없다.
- `docs/tla-audit/state-fsm-gap-2026-04-13.md` Bug #1(PR #6834, `keeper_keepalive.ml:774-836`)은 **data record 스토어와 FSM condition 스토어 간 비동기**가 만든 one-way trap이었다. 감사 문서 §5는 P4 `KeeperRecoveryOrchestration.tla` 신규를 제안했으나 아직 spec 파일이 없다.
- 대시보드 관점에서 각 FSM이 `dashboard/src/components/keeper-*.ts`의 개별 위젯으로 흩어져 있어 "이 keeper의 현재 상태가 invariants를 만족하는가"를 한눈에 볼 수 없다.

이 RFC는 **새 controller를 만들지 않고**, 기존 sub-spec들 사이의 일관성을 관찰하는 composition observer를 spec + OCaml + dashboard payload 계층으로 정의한다.

## 2. Scope

포함:

1. `specs/keeper-state-machine/KeeperCompositeLifecycle.tla` 신규 — projection-style observer spec. state explosion 없이 joint invariants 5개 + liveness 2개 + bug model 3종.
2. `KeeperCompositeLifecycle.cfg`(clean) + buggy cfg 3개 — clean은 전 invariant 통과, buggy 3개는 서로 다른 invariant를 위반한다 (`feedback_tla-spec-audit-outcome-trichotomy.md`).
3. `state-fsm-gap-2026-04-13.md` P4(RecoveryOrchestration) 제안을 별도 spec 파일 대신 이 composite 안에 `RecoveryTwoStoreSync` invariant로 흡수.
4. OCaml observer 모듈 계약(문서만, 구현은 후속 PR): `lib/keeper/keeper_composite_observer.ml{,i}`, `Keeper_registry.registry_entry` 파생 필드, event bus broadcast.
5. 대시보드 payload shape: `/api/keepers/:name/composite` JSON 스키마.

제외:

- 실제 OCaml observer 구현, dashboard `/fsm` hub 페이지 구현 — 후속 세션의 Phase 1~4 PR에서 순차 진행 (`docs/design/dashboard-fsm-redesign.md` 참조).
- P1(`TurnSucceeded` spec-code divergence) 수정 — 이 RFC와 직교한 fix로, 별도 PR에서 `KeeperStateMachine.tla`를 OCaml에 정렬한다. 이 RFC는 P1이 수정되었다는 가정 없이도 동작한다.
- Observer가 sub-FSM의 transition 권한을 획득하는 것.

## 3. Relationship to RFC-0002

RFC-0002는 11-state parent phase FSM을 pure function `derive_phase` + `apply_event`로 1급 구성했다. RFC-0003은 그 위에 **transition을 하나도 추가하지 않는다**. 관계는 다음과 같다:

- RFC-0002: 개별 keeper의 lifecycle ownership (측정 → 이벤트 → 조건 → phase).
- RFC-0003: 한 turn 안에서 여러 도메인 FSM 간 ordering/atomicity를 관찰.
- RFC-0002의 11-state → 6-state projection 규칙은 RFC-0003 spec 서두 `Comment A`에 명시한다. `{Offline, Paused, Stopped, Crashed, Restarting, Dead}`는 모두 `Stable`로 접어 turn cycle 밖에 둔다.

이 RFC의 invariants가 위반된다 해도 RFC-0002의 단일 FSM 동작은 여전히 올바르다. 단, joint property가 깨지면 운영자는 "FSM은 정상이지만 전체 시스템이 turn cycle을 잘못 진행 중"임을 관찰할 수 있어야 한다.

## 4. Meta-FSM Identity

### 세 후보와 선택

| 후보 | 설명 | 채택 여부 |
|------|------|-----------|
| **C1 Hierarchical parent** | RFC-0002의 11-state를 parent로 삼고 Decision/Cascade/Memory를 guard로 매다는 HSM | **거절** |
| **C2 Turn-cycle root** | `KeeperTurnCycle.tla`를 composition root로 하고 나머지를 하위에 위치 | **거절** |
| **C3 Event-driven projection** | `Context_measured` + OAS envelope를 coordination hub로 보고, 관찰 가능한 projection variables + joint invariants만 선언 | **채택** |

C1을 거절한 구조적 이유: Decision/Cascade/Memory는 turn 내부에서만 의미 있는 상태를 갖는다. 이를 parent-child로 강제하면 `Paused`, `Crashed`, `Restarting` 같은 phase에서도 child FSM의 state를 정의해야 하는데, 현실에서 그 state는 존재하지 않거나 stale하다. 타입이 거짓말하는 spec이 된다.

C2를 거절한 이유: `KeeperTurnCycle.tla`는 turn의 물리적 시퀀스(`prompting/awaiting/tool_call/...`)를 모델링한다. 여기에 Cascade profile이나 Decision tier 같은 상위 개념을 얹으면 spec의 추상화 레벨이 뒤집힌다.

C3 채택 이유: 이미 `Context_measured` + `auto_rules_summary`가 hub 역할을 하고 있고, `Keeper_guard`의 priority ordering(3/4/5)으로 de facto serialization도 성립한다. 새 identifier를 만들지 않고 기존 identifier를 projection으로 재사용한다 (`feedback_no-derived-tag-when-existing-identifier-suffices.md`).

## 5. Spec Summary — `KeeperCompositeLifecycle.tla`

### Projected state variables

| 변수 | 출처 | 값 도메인 | 비고 |
|------|------|-----------|------|
| `ksm_phase` | `KeeperStateMachine.tla` 12-state → 7-state 투사 | `{Running, Failing, Overflowed, Compacting, HandingOff, Draining, Stable}` | Lossy projection. Stable은 turn cycle 밖 |
| `ktc_turn_phase` | `KeeperTurnCycle.tla` / `keeper_unified_turn.ml` | `{idle, prompting, executing, compacting, finalizing}` | |
| `kdp_decision` | `KeeperDecisionPipeline.tla` | `{undecided, guard_ok, gate_rejected, tool_policy_selected}` | Narrow projection |
| `kcl_cascade_state` | `CascadeLiveness.tla` | `{idle, selecting, trying, done, exhausted}` | |
| `kmc_compaction` | `MemoryCompaction.tla` | `{accumulating, compacting, done}` | |
| `shared_measurement` | `Context_measured` | `Nat` (0 = none, else snapshot id) | **hub** |
| `measurement_turn` | `turn_tick` at capture | `Nat` | ordering |
| `turn_tick` | monotone counter | `0..MaxTurnTicks` | model bound |

### Projected state contracts

각 projected state는 "이름만 있는 배지"가 아니라, 의미와 전이 근거가 있어야 한다.

#### KSM

| State | 의미 | 들어올 때 | 나갈 때 |
|------|------|-----------|---------|
| `Running` | healthy parent lifecycle | normal init / recovery / compaction done / handoff done | failing, overflowed, compacting, handoff, draining |
| `Failing` | degraded parent lifecycle | heartbeat/turn/guard path가 healthy를 잃음 | running, overflowed, draining |
| `Overflowed` | provider-level hard context overflow latched | prompt가 max context를 초과함 | compacting(auto-compact), running(operator clear), draining |
| `Compacting` | post-turn compaction owns parent lifecycle | compaction entry action fired | running(compaction done), overflowed(compaction failed), failing, draining |
| `HandingOff` | generation rollover in progress | handoff entry action fired | running(handoff done), failing, draining |
| `Draining` | graceful stop path owns lifecycle | stop requested while work may still exist | stable bucket via stopped/crashed terminal states |
| `Stable` | turn-external or terminal raw phases collapsed here | offline, paused, stopped, crashed, restarting, dead | running or another projected parent edge when lifecycle re-enters active work |

#### KTC

| State | 의미 | 들어올 때 | 나갈 때 |
|------|------|-----------|---------|
| `idle` | no live turn | no current turn / finalizing finished / overflow/failing abort | prompting, executing, compacting |
| `prompting` | turn exists and awaits measurement/prompt completion | `StartTurn` | executing, idle |
| `executing` | live turn is inside provider/tool work | live turn started or cascade attempt in flight | finalizing, compacting, idle on abort |
| `compacting` | turn is blocked on compaction completion | parent/lifecycle compaction owns the turn | idle |
| `finalizing` | post-execution cleanup before idle | cascade/provider accepted result or handoff/drain cleanup | idle |

#### KDP

| State | 의미 | 들어올 때 | 나갈 때 |
|------|------|-----------|---------|
| `undecided` | no committed decision yet | idle turn or freshly reset turn | guard_ok, gate_rejected |
| `guard_ok` | gate evaluation passed | live turn survived guard evaluation | tool_policy_selected, undecided on reset |
| `gate_rejected` | guard blocked the turn | guardrail stop or equivalent veto | undecided on reset/finalize |
| `tool_policy_selected` | tool restriction set committed | tool policy filtering completed | cascade/select execution or undecided on reset |

#### KCL

| State | 의미 | 들어올 때 | 나갈 때 |
|------|------|-----------|---------|
| `idle` | no provider path active | no live turn / turn finished / abort path | selecting, trying |
| `selecting` | provider path is being chosen | decision advanced past guard_ok | trying, exhausted |
| `trying` | provider attempt in flight | cascade slot/provider selected | done, exhausted |
| `done` | provider returned usable output | cascade/provider success accepted | idle/finalizing reset |
| `exhausted` | every cascade path failed | last provider failed without usable result | idle/failing path |

#### KMC

| State | 의미 | 들어올 때 | 나갈 때 |
|------|------|-----------|---------|
| `accumulating` | compaction not currently executing | normal steady state | compacting |
| `compacting` | memory compaction actively mutates context | compaction entry action fired | done |
| `done` | compaction completed for the observed turn | compaction completion observed | accumulating on next turn |

### Actions (narrow abstractions)

`StartTurn`, `MeasurementBroadcast`, `DecideGuard`, `SelectToolPolicy`, `StartCascadeSelection`, `SelectCascade`, `GateRejected`, `CascadeDone`, `CascadeExhausted`, `FinishTurn`, `StartCompaction`, `FinishCompaction`, `EnterFailing`, `ClearFailing`, `EnterOverflowed`, `OverflowedAutoCompact`. 총 16개. 각 action은 sub-FSM transition의 minimum projection이며, 자세한 guard는 원 spec에 위임한다.

### Safety invariants (clean cfg)

| ID | 이름 | 요지 |
|----|------|------|
| I1 | `PhaseTurnAlignment` | `ksm_phase = Compacting ⇒ ktc_turn_phase = compacting ∧ kmc_compaction = compacting` |
| I2 | `NoCascadeBeforeMeasurement` | cascade가 idle/selecting을 떠나려면 현재 turn의 measurement가 있어야 함 |
| I3 | `CompactionAtomicity` | `kmc_compaction = compacting ⇒ ksm_phase = Compacting` |
| I4 | `EventPriorityMonotone` | 한 turn에 measurement는 최대 1회 |
### Liveness (fairness 필요)

- L1 `EventualMeasurementResolves`: `prompting ~> (shared_measurement ≠ 0 ∨ turn 이동)`
- L2 `RecoveryEventuallyCompletes`: `Failing ~> Running`

L2는 `WF_vars(ClearFailing)`이 fairness에 포함되어야만 성립한다. fairness 하나가 빠지면 liveness가 즉시 무너진다.

### Bug models

| Bug | 행동 | 예상 위반 invariant |
|-----|------|-------------------|
| `BugCascadeBeforeMeasurement` | measurement 없이 SelectCascade | I2 |
| `BugCompactionDesync` | KMC만 compacting으로 진행 | I1, I3 |
세 bug는 **서로 다른 invariant를 때린다**. 모두 같은 곳을 치면 invariant 해상도가 낮다는 신호 (`feedback_tla-spec-audit-outcome-trichotomy.md`).

## 6. Observer Contract (OCaml)

### 신규 모듈

- `lib/keeper/keeper_composite_observer.mli`
  ```ocaml
  type snapshot = {
    correlation_id : string;
    run_id : string;
    ts : float;
    ksm_phase : ksm_phase;
    ktc_turn_phase : turn_phase;
    kdp_decision : decision_stage;
    kcl_cascade_state : cascade_state;
    kmc_compaction : compaction_stage;
    shared_measurement : Keeper_state_machine.auto_rules_summary option;
    invariants : invariants_check;
  }

  and invariants_check = {
    phase_turn_alignment : bool;
    no_cascade_before_measurement : bool;
    compaction_atomicity : bool;
    event_priority_monotone : bool;
  }

  val observe : Keeper_registry.registry_entry -> snapshot
  (** Pure projection. Reads the registry entry plus the most recent
      Context_measured event. No mutation, no I/O. *)
  ```

- `Keeper_registry.registry_entry`가 projected sub-FSM state를 직접 저장한다. observer는 이 필드를 읽기만 하며, lifecycle/turn code가 single writer가 된다.

### 관찰 hook 위치

- `lib/keeper/keeper_post_turn.ml:45-232` `apply_post_turn_lifecycle` — `Compaction_started/completed`, `Handoff_started/completed` 각 emit 직후 `Keeper_event_bus` 브로드캐스트.
- `lib/keeper/keeper_unified_turn.ml` — phase gate 입출.
- Topic: `keeper.composite.tick`.
- Envelope: OAS event_bus envelope `{correlation_id, run_id, ts}` (PR OAS#845, `project_oas-event-bus-envelope-2026-04-12.md`).

### 절대 하지 않는 것

- `Keeper_state_machine.apply_event` 호출.
- `Keeper_cascade_routing.select_cascade` 호출 변경.
- `registry_entry` 필드 mutation.
- 토큰 수, context byte, provider 이름 읽기/저장.

## 7. Dashboard Payload Shape

```json
GET /api/keepers/:name/composite
{
  "correlation_id": "c-2026-04-14-abc123",
  "run_id": "r-1712834000",
  "ts": 1712834000.5,
  "phase": "Running",
  "turn_phase": "executing",
  "decision": { "stage": "tool_policy_selected" },
  "cascade": { "state": "trying" },
  "compaction": { "stage": "accumulating" },
  "measurement": {
    "captured": true,
    "auto_rules": {
      "reflect": false,
      "plan": true,
      "compact": false,
      "handoff": false,
      "guardrail_stop": false,
      "guardrail_reason": null,
      "goal_drift": 0.18
    }
  },
  "is_live": true,
  "last_outcome": {
    "turn_id": 41,
    "ended_at": 1712833970.2,
    "decision_stage": "tool_policy_selected",
    "cascade_state": "done",
    "selected_model": "glm-4.5"
  },
  "invariants": {
    "phase_turn_alignment": true,
    "no_cascade_before_measurement": true,
    "compaction_atomicity": true,
    "event_priority_monotone": true
  }
}
```

Dashboard `/fsm` hub 페이지는 이 payload를 composite Cytoscape + invariants panel + event log로 렌더링한다. 렌더링 설계의 상세는 `docs/design/dashboard-fsm-redesign.md`를 따른다. `/fsm` hub를 선택한 이유는 운영자 콘솔(`/keepers/:name`)과 아키텍처 감사 뷰를 섞지 않기 위함.

## 8. Legacy Purge

`manual_reconcile` two-store는 현재 composite observer의 SSOT가 아니다. 따라서 RFC-0003 contract에서도 제외한다. parent recovery는 `Running ↔ Failing` phase transition으로만 관찰하고, composite snapshot/TLA/dashboard 어디에도 legacy sidecar나 placeholder bool을 남기지 않는다.

P1(`TurnSucceeded` spec-code divergence)은 여기서 다루지 않는다. P1은 `KeeperStateMachine.tla`의 국소 수정이며, 본 RFC와 직교한다.

## 9. Non-goals & Boundaries

| 규칙 | 근거 | 검사 방법 |
|------|------|-----------|
| Observer가 transition 권한을 갖지 않음 | `feedback_no-lifecycle-invasion-from-masc.md` | spec에 `apply_event` 호출 grep |
| MASC 레벨에 provider/model 이름 노출 금지 | `feedback_masc-model-agnostic.md` | `rg -i 'groq|ollama|claude|gpt' specs/ lib/keeper/keeper_composite_observer.*` |
| 토큰/예산 추정 금지 | `feedback_budget-belongs-in-oas.md` | spec에 `context_tokens` 같은 양 변수 없음 (audit sub-FSM에 있음) |
| OAS state mutation 금지 | `feedback_masc-oas-layer-boundary.md`, `feedback_masc-must-use-oas-agent-run.md` | observer 시그니처가 `read-only` 반환 타입 |
| 새 추상화 발명 최소화 | `feedback_no-derived-tag-when-existing-identifier-suffices.md` | 모든 변수가 기존 spec/모듈에서 1:1 투사 |

이 경계들은 RFC의 "Scope" 항목과 함께 리뷰어가 PR에서 checklist로 확인한다.

## 10. Implementation Phases

| Phase | 산출물 | 의존 | 독립 PR |
|-------|--------|------|---------|
| **0** (이번 RFC) | `KeeperCompositeLifecycle.tla` + 4 cfg + RFC-0003 + redesign plan | 없음 | 본 PR |
| 1 | Dashboard Phase 1 (cascade dehardcode + decision FSM fields + agent mini strip) | Phase 0 승인 | `docs/design/dashboard-fsm-redesign.md` §Phase 1 |
| 2 | `KeeperCompositeLifecycle` TLC 실행 + buggy cfg 검증 (4개 cfg 모두 pass/fail 확인) | Phase 0 | 독립 |
| 3 | `lib/keeper/keeper_composite_observer.ml{,i}` + registry 파생 필드 | Phase 2 | 독립 |
| 4 | `Keeper_event_bus` topic 브로드캐스트 + OAS envelope | Phase 3 | 독립 |
| 5 | Dashboard `/api/keepers/:name/composite` endpoint + `/fsm` hub | Phase 4 | redesign plan §Phase 3 |
| 6 | SSE stream + EventSource client | Phase 5 | redesign plan §Phase 4 |

Phase 1과 Phase 2는 병렬 가능하다. Phase 2~6은 이 RFC의 scope를 벗어나며 별도 issue/PR에서 진행한다.

## 11. Risks

| Risk | Mitigation |
|------|-----------|
| Projection의 정보 손실(11→6 phase) | Comment A에 projection 표 명시 + Stable 상태는 turn cycle 밖이라 joint invariant에 영향 없음을 증명 |
| Sub-spec 변경 시 composite 동기화 지연 | `tla-audit/*-fsm-gap-*.md` 패턴으로 주기적 audit, Phase 2 CI에 TLC 4 cfg 통과 gate 추가 |
| Observer snapshot stale window | `composite_view`를 Lazy + 매 read마다 재계산, SSE broadcast 시 `ts`를 필수 필드로 둠 |
| `RecoveryTwoStoreSync`가 과하게 엄격 | "Failing 내에서 data→fsm 순서"만 강제하고, terminal phase(Stopped/Dead)에서는 vacuously hold |
| SSE + cache 이중 source-of-truth | `server_dashboard_http_cache.ml`를 stream의 last_emitted로 강등, 단일 writer는 event_bus handler |

## 12. Open Questions

1. **Observer snapshot stale window 허용치** — 0ms (매번 재계산) vs 100ms (event_bus tick 주기) 중 어느 쪽이 대시보드에 더 올바른가?
2. **SSE stream 구독자 limit** — Keeper당 N 클라이언트 이상은 거부? 무제한? 초기 default 값 제안 필요.
3. **Invariants 위반 시 dashboard 표시 정책** — 단순 경고 배지 vs alert 모달 vs on-call 알람. 운영 impact와 연결.
4. **P1 수정 타이밍** — RFC-0003 spec 진입 전/후 어느 시점에 `KeeperStateMachine.tla`의 `TurnSucceeded`를 OCaml에 정렬할 것인가? 본 RFC의 buggy cfg 3개와 P1 수정이 독립이지만 CI 순서에 영향이 있다.

## 13. Scope Exclusion

- Dashboard 구현 세부 — `docs/design/dashboard-fsm-redesign.md`에 위임
- P1(`TurnSucceeded` divergence) 수정 — 별도 PR, 별도 이슈
- P2, P3(audit가 제안한 다른 항목), P5(OCaml-TLA correspondence test) — 본 RFC 이후 단계로 연기
- Meta-observer가 여러 keeper를 cross-reference 하는 fleet-level composition — 본 RFC는 keeper 단위만 다룬다

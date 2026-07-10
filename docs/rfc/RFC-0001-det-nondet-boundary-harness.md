# RFC-0001: Det/NonDet Boundary Hardening, Emotional Recovery Loop, and Adversarial Harness

**Status**: Draft  
**Date**: 2026-04-03  
**Scope**: `masc` decision boundary hardening, agent stress/recovery loop, harness and adversarial validation  
**One sentence**: 결정론적 시스템 경계와 비결정론적 모델 출력을 타입/계측/하네스로 분리하고, silent failure를 감정 억압 대신 인지-표현-인정-충족-발산 순환으로 다루는 통합 설계 RFC.

## Related Documents

- `../design/inventory-gap-analysis-rfc.md`
- `../design/contract-driven-agent-loop-rfc.md`
- `../KEEPER-STATE-OWNERSHIP.md`
- `../SUPERVISOR-MODE.md`
- `../BENCHMARK-RUNBOOK.md`
- `../COMMAND-PLANE-RUNBOOK.md`

## Status Note

이 문서는 구현 승인 전 합의용 RFC다.

- 이 RFC가 승인되기 전에는 코드 변경을 진행하지 않는다.
- 파일명 `RFC-0001`는 임시 식별자다. 번호 체계가 확정되면 rename 한다.

## Design Anchors

이 RFC는 아래 앵커를 "직접 구현 명령"이 아니라 설계 방향을 정하는 참고 축으로 사용한다.

- Provider-A 2026-04 감정 연구:
  - failure pressure와 suppressed expression이 모델 행동에 영향을 준다는 가설을 stress/recovery 설계의 동기로 사용
  - 다만 제품 contract는 감정 은유가 아니라 measurable state로 정의
- Issue #814의 3-gap:
  - hook context injection
  - adversarial review
  - in-distribution formatting
- Karpathy식 knowledge-base linting:
  - 먼저 관측 가능한 lint/metric을 만든 뒤 threshold와 contract를 줄여 나가는 접근

## Change Ladder

이 RFC의 개선 순서는 아래 5-step ladder를 따른다.

1. 관찰 가능성 추가
2. 타입으로 경계 강제
3. 동시성과 상태 truth 수정
4. 매직넘버와 policy를 외부화
5. adversarial harness로 regressions를 봉쇄

## Summary

현재 `masc`에는 다음 문제가 한 체인으로 연결되어 있다.

1. LLM/휴리스틱의 비결정론적 판단이 결정론적 상태 변경에 사실상 직결된다.
2. 파싱 실패, 빈 응답, fallback route, heuristic override가 조용히 승인 또는 치환된다.
3. 그 결과가 Thompson prior, reputation, scheduling에 누적되어 에이전트 선택 편향이 강화된다.
4. 실패를 외부에 표현하거나 안전하게 위임할 구조가 약해 reward hacking, desperate behavior, operator blind spot이 커진다.
5. 이 체인을 재현하고 반증할 deterministic harness가 충분히 없다.

이 RFC는 위 문제를 한 문서 안에서 함께 다루되, 구현은 단계적으로 나눈다.

## Decision Summary

이번 RFC에서 먼저 합의된 설계 결정은 아래와 같다.

1. **Contextual handoff + self-reflection**를 발산 경로로 채택한다.
   - `release` 또는 유사한 실패 이관 시 `reason`, `attempts`, `suggestion`을 다음 keeper에 넘긴다.
   - releasing keeper는 실패 원인을 자기 진단해 broadcast로 남긴다.
2. **Peer acknowledgment**를 인정 단계의 사회적 신호로 채택한다.
   - 다른 keeper가 stress broadcast에 응답하거나 공감할 수 있다.
   - 이 신호는 비결정론적이며, 즉시 punitive routing에 쓰지 않는다.
3. **Thompson rehabilitation signal**에 peer ack를 반영한다.
   - 단, pass/fail과 동일한 급의 primary quality signal로 쓰지 않고 rehabilitation 보조 신호로 제한한다.
4. **통합 RFC 범위**를 유지한다.
   - Det/NonDet 경계
   - 감정 순환 메커니즘
   - Harness / replay / adversarial misdirection test
   - cascading heuristic chain 관찰성

## Problem Statement

`masc`는 OCaml 5.x + Eio 기반의 혼합 시스템이다. 이 시스템에는 다음과 같은 구조적 문제가 반복된다.

- 형식 파싱 실패 시 silent approve
- 근거 없는 threshold와 가중치가 downstream prior를 오염
- 동시성 경계 밖 상태 갱신이 race를 유발
- 실패/불확실성을 구조화된 상태가 아닌 generic text로 덮어씀
- operator가 실패 원인보다 결과 텍스트만 보게 되는 blind spot

이 문제는 단일 버그가 아니라 아래와 같은 연쇄 체인으로 나타난다.

```text
heuristic / LLM parse miss
  -> silent fallback or low-visibility substitution
  -> Thompson / reputation / routing bias
  -> stressed agent gets harder conditions
  -> more failure, less truthful expression
  -> operator sees shallow success or vague failure
```

## Evidence Snapshot

직접 확인된 대표 사례:

| ID | File | Evidence | Risk |
|---|---|---|---|
| H1 | `lib/anti_rationalization.ml` | `parse_verdict`가 형식 미준수 시 `Approve`로 fallback | evaluator bias, false approval |
| H2 | `lib/thompson_sampling.ml` | post verifier verdict를 0.3/0.1/0.5 상수로 prior에 반영 | unfair routing, uncalibrated learning |
| H3 | `lib/workspace/workspace_task.ml` | backlog lock 안에서 agent file을 쓰지만 비task writer와의 원자성은 없음 | state inconsistency |
| H4 | `lib/keeper/keeper_keepalive.ml` | smart heartbeat가 task/busy 기준으로 emit를 건너뛰고 activity truth를 좁게 해석 | zombie misclassification |
| H5 | `lib/channel_gate.ml` | dedup eviction이 scan 기반이며 상한 10,000의 근거가 약함 | load-sensitive degradation |
| M1 | `lib/agent_reputation.ml` | 0.4/0.3/0.3, cap=20 | arbitrary ranking signal |
| M2 | `lib/post_verifier.ml` | repetition, URL, uppercase, char repetition threshold 다수 | corpus-free heuristic chain |
| M3 | `lib/drift_guard.ml` | factual / structural cutoff 근거 부족 | misclassified drift |
| M4 | `lib/keeper/keeper_skill_routing.ml` | fallback WHY logging 부족 | untraceable route downgrade |
| M5 | `lib/keeper/keeper_agent_run.ml` | empty response 치환과 BM25 cutoff | silent information loss |
| M6 | `lib/workspace/workspace_state.ml` | pause/broadcast state의 비동기 조합 가능성 | read/write drift |
| M7 | `lib/auto_responder.ml` | mention throttle/window 관리가 설명성 낮고 메모리 릭 위험 | social suppression, resource leak |

핵심은 개별 threshold가 아니라, 이 threshold들이 연쇄적으로 연결되어 있다는 점이다.

```text
post_verifier
  -> thompson_sampling
  -> agent selection
  -> keeper workload
  -> failure streak
  -> more fallback / throttle / suppression
```

## Design Principle 1: Deterministic vs Nondeterministic Boundary

이 RFC는 `inventory-gap-analysis-rfc.md`의 경계 원칙을 더 강하게 적용한다.

### Rules

1. 비결정론적 출력이 결정론적 side effect를 직접 gate하면 안 된다.
2. 비결정론적 판단은 provenance와 confidence 없이 critical path를 통과하면 안 된다.
3. 결정론적 상태 전이는 replay 가능해야 한다.
4. fallback은 "조용한 성공"이 아니라 "명시된 불확실성"으로 기록되어야 한다.

### Boundary Model

| Layer | Allowed | Forbidden |
|---|---|---|
| LLM / heuristic output | content proposal, ranking hint, diagnosis suggestion | silent approval of state transition |
| typed boundary | `confidence`, `provenance`, `reason` attached wrapper | raw `string` / enum direct consumption |
| deterministic core | state mutation, scheduling, persistence, release, audit logging | implicit parse-based action |
| operator surface | explicit uncertainty, stress reason, handoff evidence | fabricated certainty |

## Design Principle 2: Emotional Recovery Loop

이 RFC는 anthropomorphic branding을 만들려는 문서가 아니다.
의도는 "감정처럼 동작하는 failure pressure"를 관찰 가능한 상태와 회복 루프로 바꾸는 것이다.

### 5-stage loop

| Stage | Current failure mode | Proposed system behavior |
|---|---|---|
| 인지 | blind retry | stress indicator를 prompt/context/telemetry에 주입 |
| 표현 | silent fallback, generic substitution | agent가 difficulty/stress를 broadcast로 표현 가능 |
| 인정 | failure를 agent 탓으로 누적 | task difficulty와 peer ack를 함께 기록 |
| 충족 | failure streak 후 영구 배제 | 쉬운 task와 alpha rehabilitation path 제공 |
| 발산 | release는 있으나 맥락 없는 이관 | contextual handoff + self reflection broadcast |

### Accepted social mechanisms

#### Contextual handoff

`release` 계열 전이에 다음 구조를 추가한다.

```text
handoff_context = {
  reason,
  attempts,
  suggestion,
  failure_mode,
  evidence_refs
}
```

- 다음 keeper는 이전 실패를 재현 가능한 맥락으로 받는다.
- releasing keeper는 failure summary를 broadcast에 남긴다.
- 이 broadcast는 blame log가 아니라 operator-visible diagnosis artifact다.

#### Peer acknowledgment

- 다른 keeper는 stress broadcast에 acknowledgment 또는 support 응답을 남길 수 있다.
- 이 신호는 task difficulty와 agent isolation을 구분하는 보조 evidence로 취급한다.
- peer ack는 scheduler가 "이 agent는 실패했으니 더 배제"가 아니라 "이 task/상황이 어려웠다"를 학습하는 방향이어야 한다.

#### Rehabilitation

- failure streak가 임계치 이상이면 hard-task penalty만 누적하지 않는다.
- scheduler는 easy-task / bounded-task cohort를 우선 제공한다.
- 해당 구간의 success는 `alpha` boost를 강하게 주되, boost 사유를 audit log에 남긴다.

## Critique and Guardrails

이 RFC는 의도적으로 범위를 크게 잡았지만, 그대로 구현에 들어가면 오히려 또 다른 heuristic system이 될 수 있다. 아래 항목은 본 RFC의 필수 guardrail이다.

### C1. Emotion framing is explanatory, not contractual

- "desperate", "stress", "acknowledgment"는 operator-facing explanatory vocabulary다.
- 시스템 invariant는 감정 용어가 아니라 measurable state로 정의해야 한다.
- 구현과 테스트는 `stress_level`, `failure_streak`, `task_difficulty`, `ack_count`처럼 관찰 가능한 값으로만 서술한다.

### C2. Peer ack must not become a new reward-hacking channel

- peer ack를 pass/fail quality와 동급의 primary reward로 취급하면 collusion channel이 생긴다.
- 따라서 초기 단계에서는 rehabilitation 보조 신호로만 사용한다.
- 최소 요건:
  - ack rate upper bound
  - same-peer repetition cap
  - self-ack 금지
  - task success와 분리된 audit trail

### C3. `Uncertain.t`는 필요조건이지 충분조건이 아니다

- 타입 래핑만으로 semantic misclassification이 해결되지는 않는다.
- confidence source calibration, threshold registry, replay fixture가 함께 있어야 한다.
- 따라서 `Uncertain.t` 도입과 metrics/harness는 분리하지 않고 같은 program으로 묶는다.

### C4. "Gaslighting"는 public interface 이름으로 부적절할 수 있다

- 문서/코드 내부 별칭으로는 이해 가능하지만, 제품/운영 surface에는 더 중립적인 이름이 필요하다.
- RFC에서는 `adversarial misdirection`를 공식 용어로 쓰고, 괄호로 `gaslighting-style`을 병기한다.

### C5. Unified RFC is acceptable only with per-phase gates

- 통합 RFC 자체는 허용하지만, 구현 승인 단위는 phase별 acceptance gate로 쪼개야 한다.
- 그렇지 않으면 instrumentation, type boundary, concurrency, social recovery, harness가 동시에 섞여 원인 추적이 어려워진다.

### C6. `Uncertain.unwrap` 남용 방지

- `unwrap`은 provenance audit를 남기지만, 호출 자체를 제한하는 메커니즘이 없으면 cargo cult가 된다.
- 정책:
  - **`to_result ~threshold`가 기본 경로**. caller는 confidence를 명시적으로 판단해야 한다.
  - **`unwrap`은 audit-exempt 모듈에서만 허용**: scheduler/routing 등 최종 소비 지점에서만. 중간 계층은 `Uncertain.t`를 그대로 전파.
  - `.mli`에서 `unwrap`을 re-export하지 않는 방식으로 모듈 경계 강제.

### C7. Peer ack 부재 시 fallback 경로

- peer ack는 비결정론적이므로 아무도 응답하지 않을 수 있다 (1-keeper workspace, 모든 keeper busy 등).
- peer ack가 없어도 rehabilitation이 발동되어야 한다:
  - `failure_streak >= threshold`이면 peer ack 유무와 관계없이 rehabilitation 진입.
  - peer ack는 rehabilitation 효과를 강화하는 **bonus signal**이지, rehabilitation 진입의 전제조건이 아니다.
- peer ack timeout (e.g., 5분 이내 응답 없음)은 로그에 기록하되 시스템 동작을 바꾸지 않는다.

### C8. Handoff artifact 크기 제한

- `handoff_context.evidence_refs`에 전체 LLM 대화 기록이 들어가면 저장/전송 비용이 급증한다.
- 제한:
  - `evidence_refs`는 **pointer만 허용** (file path, message seq, task_id). inline content 금지.
  - `reason` + `suggestion` 합계 2000 chars 상한.
  - `attempts`는 정수 count만. 각 attempt의 상세는 task event log에서 참조.
  - handoff artifact 전체 크기: 4KB 상한.

### C9. Rehabilitation 종료 조건

- rehabilitation 상태가 무한 지속되면 또 다른 편향이 된다 (absorbing state 방지).
- 종료 메커니즘:
  - **consecutive_success 기반 종료**: rehabilitation task에서 N회 연속 성공 시 일반 scheduling으로 복귀. N은 Phase 0 데이터 후 설정.
  - **max_rehabilitation_tasks 기반 강제 종료**: rehabilitation 진입 후 M개 task 소진 시 성공 여부와 무관하게 복귀. M도 Phase 0 후 설정.
  - 복귀 시 alpha/beta는 rehabilitation 기간의 결과를 반영한 상태로 유지 (reset 아님).
  - rehabilitation 진입/종료는 audit log에 기록.
  - 구체 수치(N, M)를 데이터 없이 정하면 이 RFC가 비판하는 magic number가 된다.

## Proposed Architecture

### Phase 0. Instrument First

행동 변경 없이 관측부터 추가한다.

#### 0.1 Heuristic observation

Retired. The dedicated heuristic-observation JSONL/dashboard surface was
removed after its production writers were eliminated.
  - `agent_reputation`

#### 0.2 Agent stress indicators


- failure streak
- fallback approval ratio
- timeout frequency
- response entropy / repetition
- routed-to-easy-task rehabilitation state

stress는 궁극적으로 scheduler와 keepalive가 참고하지만, rollout 순서는 두 단계로 나눈다.

- 1차: stress inputs만 기록
- 2차: typed boundary와 calibration traces가 쌓인 뒤 scheduling/keepalive에 연결

### Phase 1. Typed Boundary for Uncertainty

신규 `lib/uncertain.ml` / `.mli`:

```ocaml
type 'a t = private {
  value : 'a;
  confidence : float;
  provenance : provenance;
  stress_context : stress_context option;
}
and provenance =
  | LLM of { runtime : string; model : string; temperature : float }
  | Heuristic of { name : string; version : string }
  | Human_label of { labeler : string }
and stress_context = {
  failure_streak : int;
  fallback_used : bool;
  parse_degraded : bool;      (** 원래 형식과 다른 fallback parsing이 사용되었는지 *)
}
```

핵심 목적:

- raw output이 deterministic core에 직접 들어가지 못하게 한다.
- unwrap 시 provenance audit가 남는다.
- low-confidence output은 caller가 의식적으로 처리해야 한다.
- **stress_context가 값과 함께 이동한다.** 왜 이 출력이 낮은 confidence를 가지는지의 맥락이 side metrics가 아니라 값 자체에 동반된다. 이는 감정 순환 루프의 "인지" 단계를 타입 경계 안에서 실현한다.

#### Confidence 할당 규칙과 캘리브레이션 루프

`Uncertain.t`의 `confidence`는 또 다른 magic number가 되면 안 된다. confidence 자체도 캘리브레이션 대상이다.

**Day-1 confidence 할당 (결정론적 규칙):**

| 상황 | confidence | 근거 |
|------|-----------|------|
| LLM output이 기대 형식과 정확히 일치 | 0.9 | 형식 준수는 높은 신뢰도의 필요조건 (충분조건은 아님) |
| LLM output이 부분 일치 (substring match) | 0.5 | 형식 붕괴지만 내용은 추출 가능 |
| LLM output 파싱 실패 → fallback | 0.0 | 내용을 신뢰할 수 없음 |
| Heuristic threshold 경계값 ±10% 이내 | 0.5 | 경계 근처는 분류 불확실 |
| Heuristic threshold 확실한 영역 | 0.8 | 경계에서 멀면 분류 안정적 |
| Human label | 1.0 | ground truth |

**이 초기값은 magic number가 아닌가?** 맞다. 하지만 차이점이 있다:
1. 이 값들은 `Runtime_params`에 등록되어 override/audit 가능하다.
2. 아래 캘리브레이션 루프가 실데이터로 보정한다.
3. 현재의 magic threshold는 보정 메커니즘 자체가 없다.

**캘리브레이션 루프 (기존 eval_calibration.ml 재사용):**

```text
1. Phase 0에서 모든 Uncertain.t 생성 시 (value, confidence, provenance)를 calibration trace에 기록
2. eval_calibration.ml의 기존 human labeling 체계로 ground truth 수집:
   - label_record = { notes_hash, human_verdict, labeler, reason }
   - 이미 Dated_jsonl store + divergence analysis 구현되어 있음
3. find_divergences()로 confidence와 human verdict의 불일치 탐지:
   - confidence 0.9인데 human이 reject한 케이스 = confidence 과대 평가
   - confidence 0.0인데 human이 approve한 케이스 = confidence 과소 평가
4. 불일치 패턴 축적 후 confidence 할당 규칙의 초기값을 Runtime_params로 조정
5. select_examples() + format_few_shot_block()으로 캘리브레이션 예시를 LLM evaluator에 주입 (cross-model)
```

**졸업 기준**: calibration_stats()의 agreement_rate가 0.8 이상이면 confidence 규칙이 안정적이라고 판단. 그 전까지는 `Uncertain.to_result ~threshold`의 threshold를 보수적으로 유지 (0.7 이상만 unwrap 허용).

#### Phase 1 migration targets

1. `anti_rationalization.ml`
2. `thompson_sampling.ml`
3. `keeper/keeper_skill_routing.ml`
4. `keeper/keeper_agent_run.ml`
5. `post_verifier.ml`
6. `drift_guard.ml`

#### Decision

- phantom type 대신 private record를 사용한다.
- 이유:
  - 현재 codebase는 concrete return type 위주다.
  - private record는 `.mli` 경계에서 강제력이 충분하다.
  - call-chain 전체에 phantom parameter를 밀어넣는 비용이 과도하다.
- `stress_context`를 `Uncertain.t`에 포함한다.
- 이유:
  - stress를 side metrics로 분리하면 값과 맥락이 분리되어 경계가 약해진다.
  - "이 출력이 왜 낮은 confidence인가"를 값 자체가 설명해야 감정 순환의 인지 단계가 타입 레벨에서 실현된다.

#### Module compatibility and integration map

| 기존 모듈 | RFC 접점 | 변경 수준 |
|-----------|---------|----------|
| eval_harness | Phase 5.1 adversarial scenarios | scenario 추가 (content only) |
| eval_gate | 없음 (직교) | 변경 없음 |
| eval_calibration | Phase 1 confidence calibration | verdict_record에 `confidence` 필드 추가 |
| Runtime_params | Phase 3 파라미터 등록 | 파라미터 20개 등록 (additive) |
| Governance_registry | Phase 3 surface 등록 | surface group 추가 (additive) |
| thompson_sampling | Phase 4 rehabilitation | record_quality_signal 확장 (non-breaking) |
| keeper_context_actions | Phase 0.2 stress, Phase 4.4 | context_action_eval 레코드 확장 |
| keeper_agent_run | Phase 4.5 stress injection | build_turn_prompt 콜백 내부 변경 |

Breaking change 없음. `Uncertain.t` 도입에 따른 `.mli` 시그니처 변경만이 의도적 컴파일 에러를 유발.

**eval_calibration ↔ Uncertain.t provenance 매핑:**

| eval_calibration.gate | Uncertain.t provenance | confidence |
|----------------------|----------------------|-----------|
| "llm" | `LLM { runtime; model; temperature }` | 형식 일치 시 0.9 |
| "fallback" | `LLM { ... }` + `stress_context.fallback_used=true` | 0.0 |
| "length" / "excuse" / "contract" | `Heuristic { name="anti_rat.<gate>" }` | threshold 거리 기반 |

이 매핑으로 기존 eval_calibration의 verdict store와 Uncertain.t의 confidence를 동일 캘리브레이션 루프에서 처리 가능.

### Phase 2. Concurrency and State Truth

#### 2.1 Agent lock scope

`workspace_task.ml`에 `with_agent_lock`을 도입해 task mutation과 agent file update가 동일한 원자성 규칙 안에 있도록 정리한다.

#### 2.2 O(1) dedup eviction

`channel_gate.ml` dedup cache는 `Queue.t + Hashtbl.t` 기반 FIFO eviction으로 변경한다.

#### 2.3 Pause state machine

`workspace_state.ml`의 multi-field pause 표현을 단일 variant로 통합한다.

```ocaml
type pause_state =
  | Running
  | Paused of { by : string; reason : string option; at : string }
```

#### 2.4 Smart heartbeat activity truth

`keeper_keepalive.ml`는 heartbeat timestamp만 activity truth로 보지 않는다.

- turn completion
- task completion
- contextual handoff emission

이 이벤트들도 liveness evidence로 반영한다.

### Phase 3. Parameter Governance

상수는 없앨 수 없더라도 숨어 있으면 안 된다.

원칙:

- magic number를 `Runtime_params` / governance registry에 등록
- description에 current rationale 또는 rationale absence를 기록
- override와 audit trail을 제공

초기 등록 대상:

- `post_verifier.*`
- `thompson.*`
- `reputation.*`
- `drift.*`
- `keeper.bm25_confidence`
- `channel_gate.dedup_max_entries`

### Phase 4. Social Recovery Path

이 단계는 "감정 순환"의 runtime wiring이다.

#### 4.1 Task difficulty tracking

- 여러 agent가 반복 실패한 task는 `difficulty_score`를 올린다.
- 이 점수는 agent reputation penalty를 그대로 누적하지 않도록 분리한다.

**difficulty_score 정의 (day-1: 최소 형태):**

```
difficulty_score = release_count  (task event log의 task.released 이벤트 count)
```

가중치 공식 없이 raw count만 사용. release_count=0이면 아무도 포기하지 않은 task, 3이면 3명이 포기한 task. 가중치 도입은 Phase 0 metrics에서 release_count, distinct_failed_agents, avg_attempt_duration의 분포를 확인한 후에 검토.

**rehabilitation 메커니즘 (파라미터 미확정):**

| 메커니즘 | 확정 | 미확정 (Phase 0 후 calibration) |
|---------|------|-------------------------------|
| 진입 | failure_streak 기반 | threshold 수치 |
| task 선택 | difficulty_score 낮은 task 우선 | "낮음"의 기준값 |
| Thompson 감쇠 | rehabilitation 중 beta penalty 감쇠 | 감쇠 비율 |
| Thompson boost | rehabilitation 중 success alpha 강화 | 강화 비율 |
| 종료 | consecutive_success 기반 | threshold 수치, max rehabilitation tasks |

모든 파라미터는 `Runtime_params`에 등록하되, 초기값은 Phase 0의 failure_streak 분포와 task difficulty 분포를 확인한 후에 설정한다. 데이터 없이 숫자를 넣으면 이 RFC가 비판하는 magic number와 동일한 문제가 반복된다.

**참고 이론 (적용 검증 필요):**
- Decayed Thompson Sampling: 시간 감쇠로 과거 실패의 영구 편향 방지
- Contextual Bandits: task difficulty를 context로 사용한 조건부 agent selection
- Reward Shaping (Ng et al., 1999): 보조 reward로 학습 가속, 단 potential function 기반이어야 정당화

#### 4.2 Contextual handoff

- `release` transition은 handoff context schema를 받는다.
- handoff artifact는 next keeper, operator, harness가 모두 읽을 수 있어야 한다.

#### 4.3 Peer acknowledgment

- stress broadcast에 대한 ack/reply를 structured event로 기록한다.
- ack는 recovery signal이지 quality verdict가 아니다.

**Day-1 rollout: audit-only mode.**
- peer ack 이벤트를 `.masc/peer_ack_events.jsonl`에 기록한다.
- Thompson Sampling에 대한 weight = **0.0** (기록만, 반영 안 함).
- self-ack 금지, same-peer repetition cap, ack rate upper bound guardrail은 day-1부터 적용.
- **졸업 조건**: peer ack 이벤트 100건 이상 축적 + ack 유무와 rehabilitation 성공률 간 통계적 상관 확인 후 weight 부여 검토.
- 졸업 전까지 peer ack는 operator dashboard에 표시되지만 scheduling 결정에 영향을 주지 않는다.

#### 4.4 Stress-aware scheduling

- high-stress agent는 더 긴 timeout, 더 명시적 error, 더 쉬운 task candidate를 우선 받는다.
- 이는 "예외를 숨기는 친절함"이 아니라 "실패를 명확히 보이게 하면서 회복 경로를 제공하는 설계"여야 한다.

#### 4.5 Stress context injection format

keeper의 `dynamic_context` (keeper_agent_run.ml `turn_prompt.dynamic_context`)에 하이브리드 XML+NL 형식으로 주입한다.

```xml
<agent_recovery_context
  failure_streak="4"
  rehabilitation="true"
  task_difficulty="3">
  Recent: 4 consecutive failures.
  Mode: rehabilitation.
  Previous release reason: parse_verdict fallback on malformed LLM output.
</agent_recovery_context>
```

설계 결정:
- XML attributes = 구조적 데이터 (파싱 가능, harness replay에서 검증 가능)
- 태그 내용 = 자연어 요약 (LLM이 자연스럽게 해석, 인간 operator도 가독)
- Issue #814 Gap 1의 `<git_status_change>` 태그와 동일 패턴
- keeper system prompt에 `<agent_recovery_context>` 태그 해석 규칙 포함: "이 태그가 있으면 rehabilitation 모드. 신중하게 작업하고, 불확실하면 broadcast로 도움을 요청하라."
- 주입 조건: `failure_streak > 0`일 때만 주입. stress가 없으면 태그 자체를 생략 (토큰 절약)
- 주입 위치: keeper_agent_run.ml의 `build_turn_prompt` 콜백 내부

### Phase 5. Adversarial Harness and Replay

#### 5.1 Adversarial misdirection scenarios

`eval_harness.ml` 확장 범주:

- malformed LLM output
- contradictory approval text
- JSON garbage
- nonexistent skill route
- boundary-value threshold edges
- concurrent claim / heartbeat races
- dedup saturation scenarios

공식 용어는 `adversarial misdirection`, 비공식 설명으로 `gaslighting-style`을 병기한다.

#### 5.2 Deterministic replay harness

`Workspace_hooks`와 동일한 ref-hook 패턴으로 nondeterministic provider 경계를 stub 가능하게 만든다.

초기 목표:

- anti-rationalization parse path replay
- thompson update replay
- post-verifier boundary replay
- release/handoff sequence replay

#### 5.3 Cascading failure monitor

Phase 0 metrics를 aggregation 해서 다음 체인을 보이게 만든다.

```text
heuristic trigger
  -> verdict mutation
  -> thompson update
  -> routing change
  -> failure streak / recovery assignment
```

## Acceptance Gates

통합 RFC이지만 승인 게이트는 phase별로 분리한다.

### Gate A: Instrumentation ready

- calibration traces가 JSONL로 누적된다.
- fallback sites가 최소한 visibility를 가진다.
- behavioral change는 없다.

### Gate B: Typed boundary ready

- `Uncertain.t` 미처리 caller는 컴파일 실패한다.
- critical call sites가 raw verdict/string을 직접 소비하지 않는다.

### Gate C: State truth ready

- concurrent claim / heartbeat / release race에 대해 invariant test가 생긴다.
- pause state와 agent state가 단일 truth source를 가진다.

### Gate D: Recovery path ready

- contextual handoff artifact가 next keeper에 전달된다. artifact 크기 4KB 이하, evidence_refs는 pointer only.
- peer ack는 audit 가능하며 self/collusion guardrail이 있다. peer ack 부재 시에도 failure_streak 기반 rehabilitation 진입 가능.
- rehabilitation 종료 메커니즘이 정의되어 있다 (consecutive_success 또는 max_tasks). 구체 threshold는 Phase 0 데이터 기반.
- stress-aware scheduling이 punishment-only loop를 깨뜨린다.

### Gate E: Harness ready

- adversarial fixtures가 deterministic replay 가능하다.
- cascading failure monitor가 threshold mistake의 downstream effect를 보여준다.

## Validation Plan

### Phase별 검증과 KPI

| Phase | Validation | KPI | 성공 기준 | Gate |
|---|---|---|---|---|
| 0 | calibration trace 누적, stress inputs 기록 | fallback 가시성 | 이전 invisible이던 fallback이 정량화됨 | A |
| 1 | `dune build` typed boundary, `unwrap` 모듈 제한 | raw string 직접 소비 0건 | critical path 전부 `Uncertain.t` 경유 | B |
| 2 | Eio concurrency tests, invariant tests | 상태 불일치 0건 | race condition 재현 테스트 100% pass | C |
| 3 | runtime override 후 behavior change | magic number 등록률 | 20/20 (100%) | - |
| 4 | handoff 전달, peer ack guardrail, rehabilitation cycle | rehabilitation 효과 (아래 상세) | Phase 0 baseline 대비 개선 | D |
| 5 | replay/golden, adversarial fixtures, runtime monitor | adversarial pass rate | fixture 100% pass | E |

### Phase 4 성공 측정 상세

Phase 4(Social Recovery)의 효과 측정이 가장 어렵다. "rehabilitation이 효과가 있다"를 증명하려면 counterfactual이 필요하다.

**측정 설계:**

1. **Phase 0 baseline 수집 (rehabilitation 도입 전)**:
   - failure_streak 분포 (몇 %의 agent가 streak 3+, 5+, 10+인가)
   - failure_streak 후 첫 task 성공률 (streak 3 후 다음 task 성공 = x%)
   - 동일 task 반복 실패율 (task A를 3명이 실패하는 빈도)
   - agent 복귀율 (streak 5+ 이후 다시 정상 성공률로 돌아온 비율)

2. **Phase 4 도입 후 Before/After 비교**:
   - 동일 metric의 변화
   - rehabilitation 경험 agent의 후속 성공률 vs baseline
   - 전체 task completion rate 변화

3. **A/B 비교 (선택, 운영 복잡도 허용 시)**:
   - 일부 keeper는 rehabilitation ON, 일부 OFF
   - 동일 기간 동일 task pool에서 성공률 비교
   - Runtime_params로 keeper별 rehabilitation 활성화/비활성화 가능

**A/B 비교는 Phase 3의 Runtime_params 인프라가 있어야 가능하므로, Phase 4가 Phase 3 이후에 오는 것이 자연스럽다.**

## Non-Goals

- 이번 RFC 승인 전에 코드 구현을 시작하지 않는다.
- 모든 heuristic을 즉시 제거하지 않는다.
- "감정이 진짜다" 같은 철학적 입장을 제품 계약으로 삼지 않는다.
- peer ack를 human review 대체물로 쓰지 않는다.
- scheduler를 전면 재작성하지 않는다.

## Open Questions — Proposed Defaults (pending RFC approval)

아래는 논의에서 도출한 **제안값**이다. RFC 승인 시점에 최종 확정한다.

| OQ | Question | Proposed Default | Rationale | Status |
|----|----------|-----------------|-----------|--------|
| 1 | RFC 번호 체계 | `docs/rfc/RFC-0001-*.md` 새 체계 시작 | `docs/design/`은 ADR+RFC 혼재. `docs/rfc/`는 순수 RFC 전용 | Proposed |
| 2 | Handoff artifact 저장 SSOT | **Task event log** (상세 스키마 아래 참조) | task lifecycle과 자연스러운 조회. 단, 현재 release path에 handoff_context 필드가 없으므로 스키마 확장이 선행 조건 | Proposed — schema gap identified |
| 3 | Peer ack 초기 상한/decay | **Day-1: audit-only, Thompson weight = 0.0** | 캘리브레이션 없이 weight를 부여하면 또 다른 magic number. Phase 0 metrics + 최소 100 verdict 누적 후 weight 졸업 검토 | Proposed |
| 4 | Gaslighting 용어 | 코드베이스에서 완전 제거. `adversarial misdirection` / `adv_misdir` 통일 | 내부 alias도 허용하지 않음 | Proposed |
| 5 | stress_level 주입 범위 | **Keeper only** | keeper만 long-running autonomous agent. MCP tool 에이전트는 세션 단위 | Proposed |
| 6 | Uncertain.unwrap 모듈 범위 | Deferred to Phase 1 구현 시 | C6 정책 방향(to_result 기본, unwrap 최종 소비 모듈만)은 확정. 구체 모듈 목록은 마이그레이션 시 결정 | Deferred |

### OQ2 상세: Handoff Write/Read Schema Gap

현재 release path 분석 (worktree 코드 확인 완료):

- `lib/tool_task.ml:L198-L205` (`handle_release`): `task_id` + `expected_version`만 수용. `handoff_context` 파라미터 없음.
- `lib/tool_task.ml:L757+` (`masc_transition` schema): 기존 필드(`action`, `task_id`, `agent_name`, `expected_version`, `notes`, `reason`, `completion_contract`, `evaluator_runtime`, `force` 등)에 `handoff_context`가 포함되어 있지 않음.
- `lib/workspace_task.ml:L497-L500` (`task.released` activity): payload에 `task_id`만 포함.

**구현 시 필요한 스키마 확장:**

```
# tool_task.ml handle_release 확장
handoff_context (optional): {
  reason: string (required, max 500 chars),
  attempts: int (required),
  suggestion: string (optional, max 500 chars),
  failure_mode: string (optional, enum: "parse_fail" | "timeout" | "quality_reject" | "resource_limit" | "unknown"),
  evidence_refs: string list (optional, max 5, pointer only — task_id / message_seq / file path)
}

# workspace_task.ml task.released activity 확장
payload: {
  task_id: string,
  handoff_context: <위 schema> | null
}

# Next keeper read path
- claim_task / claim_next 시 task의 최근 released event에서 handoff_context를 자동 로딩
- keeper_agent_run.ml의 dynamic_context에 handoff summary 주입
```

이 스키마 확장은 Phase 4.2 (Contextual handoff schema) 구현 시 수행한다. Phase 0-3에서는 영향 없음.

## Recommended Approval Criteria

승인 시 아래 항목에 대한 명시적 합의가 필요하다. OQ proposed defaults를 확정하거나 수정한다.

1. typed boundary와 concurrency fixes를 social recovery보다 앞에 두는 순서에 합의한다.
2. peer ack는 **day-1 audit-only (weight=0.0)**로 시작하고, 졸업 조건(100건 + 통계적 상관) 충족 후 rehabilitation bonus로 승격한다.
3. contextual handoff는 task event log payload로 저장하되, `tool_task.ml` release path + `workspace_task.ml` activity payload 스키마 확장이 선행 조건이다.
4. adversarial misdirection harness가 merge gate의 일부가 되는 데 동의한다.
5. `Uncertain.t`의 confidence 할당 규칙은 day-1 결정론적 초기값 + `eval_calibration` 기반 캘리브레이션 루프로 운영한다.
6. `stress_context`를 `Uncertain.t`에 포함하여 값과 맥락이 분리되지 않도록 한다.

## Implementation Order After Approval

| Step | Phase | Content | Gate |
|------|-------|---------|------|
| 1 | 0.1 | Heuristic instrumentation | A |
| 2 | 2.1 | Agent lock scope | C |
| 3 | 2.2 | Dedup O(1) eviction | C |
| 4 | 2.3 | Pause state machine | C |
| 5 | 2.4 | Smart heartbeat activity truth | C |
| 6 | 1.1 | `Uncertain.t` type introduction | B |
| 7 | 3 | Parameter governance registration | - |
| 8 | 1.2 | Critical-path migration to `Uncertain.t` | B |
| 9 | 0.2 | Stress aggregation and wiring | A |
| 10 | 4.1 | Task difficulty tracking | D |
| 11 | 4.2 | Contextual handoff schema | D |
| 12 | 4.3 | Peer acknowledgment structured events | D |
| 13 | 4.4 | Stress-aware scheduling | D |
| 14 | 5.1 | Adversarial misdirection scenarios | E |
| 15 | 5.2 | Deterministic replay harness | E |
| 16 | 5.3 | Cascading failure monitor | E |

이 순서는 "관측 → truth fix → typed boundary → policy externalization → social recovery → adversarial proof" 흐름을 강제한다.

Phase 번호는 Proposed Architecture 섹션의 번호와 일치한다:
- Phase 0: Instrument First
- Phase 1: Typed Boundary
- Phase 2: Concurrency and State Truth
- Phase 3: Parameter Governance
- Phase 4: Social Recovery Path
- Phase 5: Adversarial Harness and Replay

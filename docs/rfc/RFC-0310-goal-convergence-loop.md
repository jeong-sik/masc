---
rfc: "0310"
title: "Goal convergence loop — typed metric contract, LLM evaluator boundary, audited override"
status: Draft
created: 2026-07-06
updated: 2026-07-06
author: vincent
supersedes: []
superseded_by: null
related: ["0296", "0304", "0309"]
implementation_prs: []
---

# RFC-0310: Goal convergence loop — typed metric contract, LLM evaluator boundary, audited override

Tracking issue: #23307. Related findings: #23417, #18840(인접), PR #23319 / #23335 / #23322 리뷰.

## 1. Problem

Goal Store에는 FSM, 저장, 검증, 대시보드 표면이 있지만 **goal을 실제로 진행/완료시키는 실행 루프가 없다.** 2026-07-06 48h 감사로 확인된 현재 상태:

- [근거] `lib/goal/convergence.ml` — `check_convergence`는 `AllSubTasksDone` / `MetricMet` / `StagnationDetected` 3개 signal 중 **`MetricMet`을 생성할 수 없다** (metric 입력이 evaluator에 전달되지 않음). 확인 2026-07-06, Confidence High.
- [근거] `lib/workspace_goals.ml:571` — 유일한 caller(#23319)가 `~iterations_without_progress:0`을 하드코딩해 `StagnationDetected`(threshold 5)는 **도달 불가**. cross-turn no-progress 카운터는 주인이 없다.
- [근거] `lib/workspace_goals.ml:531` — metric 문자열이 존재하면 평가 없이 완료 차단. 측정 소스가 없으므로 활성 goal 79개 중 50개(63%)가 `override_note` 없이는 영구 완료 불가 (2026-07-06 production 실측).
- [근거] `override_note`는 goal_events에 기록되지 않는 무감사 자유텍스트 우회 — 모든 에이전트가 override를 학습하는 gate erosion 경로.
- [근거] `lib/workspace_goals.ml:666-667` — #23335가 read-time 스위퍼로 정책 ID `G-GHYG`(RFC 0건)와 14일 매직넘버를 코드에서 발명, apply는 `Goal_phase.decide_transition` FSM SSOT를 우회한 직접 phase write + 무스코프 TOCTOU.

요약: 완료 판정은 통과 불가능한 형식 조건으로 막혀 있고(gate), 진행은 아무도 굴리지 않으며(loop 부재), 예외 경로는 감사되지 않는다(override). #23322의 `Goal_verification_failed` re-wake만이 스펙 정합으로 착지한 상태다.

## 2. Non-goals

- Goal 수/기간에 대한 cap 도입 (스펙: 제약은 집계 대상이지 정지 조건이 아님)
- Keeper turn 경로에 goal 게이트 추가 (keeper lane과 goal은 약결합 유지)
- 기존 Goal FSM(`Goal_phase.decide_transition`) 재설계 — 본 RFC는 SSOT를 **경유**한다

## 3. Design

### 3.1 Typed metric contract (Parse, don't validate)

`metric : string option`을 typed 계약으로 승격한다:

```ocaml
type metric_kind =
  | Count of { target : int }
  | Percentage of { target : float }        (* 0.0 .. 100.0 *)
  | Boolean                                  (* verified true/false *)
  | Judged of { criteria : string }          (* free-form NL — LLM evaluator 경계 *)

type metric = {
  kind : metric_kind;
  observed : metric_observation option;      (* 마지막 평가 결과 + provenance *)
}

and metric_observation = {
  value : metric_value;
  evaluated_at : float;
  evaluator : evaluator_ref;                 (* Llm of { model_run_id } | Reported of { actor } *)
}
```

- upsert 경계에서 파싱: 기존 free-form 문자열은 `Judged { criteria }`로 수용 (마이그레이션 비용 0, 조용한 거부 없음).
- **write-time 강제**: 신규 goal이 Executing(active)으로 들어오려면 metric 또는 명시적 `metric_waiver` 필드가 필요. 기존 goal은 §5 마이그레이션.

### 3.2 LLM evaluator 경계 — MetricMet을 살린다

- `Judged` metric의 평가는 휴리스틱이 아니라 **LLM judge 경계**(기존 structured judge/Fusion 경로 재사용)로 수행하고, 결과를 `metric_observation`으로 영속화한다.
- `Count`/`Percentage`/`Boolean`은 결정론적 비교 — LLM 불필요.
- `check_convergence`에 metric 입력을 배선해 `MetricMet`이 실제로 생성 가능해진다.
- **fail-closed 방향**: evaluator unavailable 시 완료는 계속 차단되지만, 조용히 막는 대신 HITL 승인 큐로 nomination (operator가 결정). Keeper는 어떤 경우에도 블러킹되지 않는다.

### 3.3 Stagnation의 주인 — goal loop

- goal별 `iterations_without_progress`를 goal store에 영속화하고, goal review 사이클(스케줄러 wake 또는 goal-linked task 종료 시점)이 소유·증감한다.
- `lib/workspace_goals.ml:571`의 `~iterations_without_progress:0` 하드코딩 제거.
- `StagnationDetected` 발생 시 동작은 **pause가 아니라 wake**: #23322의 `Goal_verification_failed`와 같은 typed stimulus 계열로 `Goal_stagnation_detected`를 추가해 담당 keeper를 깨운다.

**구현 노트 (2026-07-08)**: `Keeper_event_queue.Goal_stagnation` typed stimulus가 먼저 착지했다. 단, 진행 척도로 §3.3 원안의 `iterations_without_progress` 카운터(주인 없음·미영속) 대신 goal의 **`updated_at` 벽시계 staleness**를 사용한다. 근거: `updated_at`은 이미 goal store에 영속되고 모든 goal mutation(metric/phase/note)에 bump되므로, 별도 카운터를 소유·영속하지 않고도 "미진행" 프록시가 된다. episode 키 = (goal_id, updated_at)로 edge 성질 확보 — 진행 시 새 episode, 미진행 시 live-queue identity dedup + reaction-ledger `turn_started_seen` 가드로 episode당 1회만 발화(consume 후 재발화 없음). detector는 heartbeat tick의 `Keeper_goal_stagnation_wake` 스캔, live phase 게이트는 `Goal_phase.admits_self_directed_progress`(Executing만), threshold는 `keeper.goal.stagnation_threshold_sec`(기본 3600s). LLM evaluator 배선(Phase 2 전체)과 `workspace_goals.ml:571` `~iterations_without_progress:0` 하드코딩 제거는 여전히 잔여 — 본 착지는 wake 경로에 한정된다.

### 3.4 Audited override

- `override_note` 자유텍스트 우회를 typed 이벤트로 대체:
  `Goal_completion_override { actor; note; overridden_signal; at }` → `goal_events.jsonl` 영속화.
- actor 없는 override는 거부. 대시보드에 override 이력 표면.

### 3.5 Hygiene 흡수 — G-GHYG를 이 RFC가 소유

#23335의 스위퍼는 다음으로 정규화한다:

- 14일 임계값 → config knob (`goal_hygiene_stale_executing_age_days`, 기본값은 config SSOT에 선언). "abandoned vs 장기 실행" 판단이 필요한 경계므로 스위퍼는 **nomination까지만** 하고 판단은 operator HITL.
- apply 경로: 명시적 `goal_ids` 인자 + 리뷰 스냅샷 바인딩 `expected_version` CAS + `Goal_phase.decide_transition(Operator_block)` 경유 (FSM SSOT 준수). 부분 실패 시에도 `applied_goal_ids` 반환.
- 정책 ID `G-GHYG` 문서 근거 = 본 RFC.

## 4. Observability

- metric 평가마다 `metric_evaluated` 이벤트 (goal_id, kind, value, evaluator provenance).
- stagnation 카운터 변화, override, hygiene nomination/apply 전부 goal_events.jsonl + 대시보드 goal detail에 표면.

## 5. Migration

1. 기존 `metric : string option` → `Judged { criteria }` 자동 파싱 (lossless).
2. metricless active goal 50건: 일괄 차단하지 않는다. hygiene nomination 목록으로 operator에게 표면 → metric 부여 / `metric_waiver` / close 중 선택.
3. `dashboard_goals_types_accessor.ml:49` 등 stale "has no caller" 주석 정리.

## 6. Verification

- Alcotest: (a) `MetricMet` 생성 가능 (Count/Percentage/Boolean/Judged 각각), (b) stagnation 카운터 증감·threshold 도달 시 `Goal_stagnation_detected` stimulus 방출, (c) override가 actor 없이 거부 + 이벤트 영속화, (d) hygiene apply의 CAS mismatch 거부.
- 하네스: goal 생성 → task 완료 → metric 평가 → request_complete 통과 경로의 end-to-end 계약 케이스.
- 회귀 가드: `~iterations_without_progress:0` 리터럴 재출현을 잡는 structure 검사 (파일 고유 구분자 기준).

## 7. Rollout / Removal targets

- Phase 1: typed metric 파서 + observation 영속화 + audited override (behavior-preserving).
- Phase 2: LLM evaluator 배선 + stagnation 카운터 소유권 + wake stimulus.
- Phase 3: write-time 강제 + hygiene 정규화.
- **Removal**: `lib/workspace_goals.ml:571` 하드코딩, 무감사 override_note 경로, G-GHYG 코드 발명 정책 ID의 인라인 정의.

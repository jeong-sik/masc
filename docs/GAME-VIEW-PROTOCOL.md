# GAME VIEW PROTOCOL (Draft v0.1)

이 문서는 별도 세션에서 `game view`를 구현할 때, `keeper + 의사결정 + 사회실험 + TRPG`를 동일한 계약으로 붙이기 위한 프로토콜 초안이다.

## 1. 목적

- UI/뷰 레이어와 코어 엔진 레이어를 분리한다.
- 모델/엔진이 바뀌어도 메시지 계약은 유지한다.
- 의사결정 게이트와 verifier 게이트를 공통 규칙으로 강제한다.

## 2. 범위

- JSON 기반 command/event/result/error 계약
- 공통 envelope
- 도메인별 payload 계약
- 상태 전이 및 게이트 규칙

## 3. 공통 Envelope

모든 메시지는 아래 envelope를 사용한다.

```json
{
  "protocol": "masc.game-view/0.1",
  "message_id": "uuid-or-snowflake",
  "session_id": "sess-...",
  "trace_id": "trace-...",
  "timestamp": "2026-02-15T11:11:11Z",
  "type": "command",
  "domain": "decision",
  "name": "decision.create",
  "correlation_id": "optional-parent-message-id",
  "causation_id": "optional-direct-cause-message-id",
  "idempotency_key": "optional-client-key",
  "payload": {}
}
```

## 4. 메시지 타입

- `command`: 클라이언트가 엔진에 요청
- `event`: 엔진이 상태 변경/진행 이벤트 발행
- `result`: command 처리 최종 결과
- `error`: 처리 실패
- `state`: 현재 스냅샷 전달

## 5. 공통 Error 계약

```json
{
  "protocol": "masc.game-view/0.1",
  "type": "error",
  "domain": "decision",
  "name": "decision.create",
  "payload": {
    "code": "VALIDATION_ERROR",
    "message": "issue is required",
    "retryable": false,
    "details": {}
  }
}
```

## 6. 도메인 계약

### 6.1 Decision Domain

명령:

- `decision.create`
- `decision.propose`
- `decision.score`
- `decision.vote`
- `decision.finalize`

`decision.create` payload:

```json
{
  "issue": "문제 정의",
  "options": ["A", "B", "C"],
  "criteria": ["impact", "risk", "cost", "reversibility"],
  "weights": {
    "impact": 0.4,
    "risk": 0.3,
    "cost": 0.2,
    "reversibility": 0.1
  }
}
```

결과 필수 필드:

- `selected_option`
- `scores`
- `rationale`
- `dissent`
- `confidence`

### 6.2 Social Experiment Domain

명령:

- `experiment.define`
- `experiment.start`
- `experiment.observe`
- `experiment.stop`
- `experiment.report`

`experiment.define` payload:

```json
{
  "hypothesis": "가설",
  "treatment": "개입 정의",
  "control": "비교군 정의",
  "metrics": ["engagement", "repeat_rate"],
  "window_sec": 3600,
  "guardrails": ["no-spam", "respect-rate-limit"]
}
```

결과 필수 필드:

- `effect_size`
- `confidence_interval`
- `side_effects`
- `recommendation`

### 6.3 TRPG Domain

명령:

- `trpg.scene.start`
- `trpg.action.submit`
- `trpg.roll.resolve`
- `trpg.tick`
- `trpg.scene.end`

`trpg.scene.start` payload:

```json
{
  "scene_id": "scene-001",
  "world_state": {
    "location": "market",
    "threat": "low",
    "clock": 3
  },
  "party_state": {
    "hp": 23,
    "resources": {
      "gold": 120
    }
  },
  "quest_state": {
    "objective": "정보 수집",
    "progress": 0.35
  }
}
```

결과 필수 필드:

- `next_scene_or_state`
- `resolved_effects`
- `risk_delta`
- `story_log`

### 6.4 Keeper Domain

명령:

- `keeper.reflect`
- `keeper.plan`
- `keeper.compaction.check`
- `keeper.handoff.check`

`keeper.reflect` payload:

```json
{
  "recent_turns": [
    "최근 발화 1",
    "최근 발화 2"
  ],
  "current_goal": "현재 목표",
  "short_term_goal": "단기 목표",
  "mid_term_goal": "중기 목표",
  "long_term_goal": "장기 목표"
}
```

결과 필수 필드:

- `self_assessment`
- `repetition_risk`
- `goal_alignment_score`
- `next_adjustment`

## 7. 게이트 규칙

- 모든 `experiment.start`와 `trpg.action.submit`는 선행 `decision.finalize`를 참조해야 한다.
- 모든 high-impact 액션은 `verifier` 결과가 `PASS` 또는 허용 가능한 `WARN`이어야 한다.
- `keeper.compaction.check`는 `repetition_risk`, `goal_alignment_score`, `context_ratio`를 함께 평가한다.
- `keeper.handoff.check`는 `context_ratio + continuity_score + unfinished_work`를 함께 평가한다.
- `continuity_score`와 `unfinished_work`는 MODEL evaluator 결과를 우선 사용하고, 실패 시 fallback 점수를 사용한다.
- handoff 판단은 `handoff_score = avg(context_ratio, continuity_score, unfinished_work)`를 기준으로 수행한다.

## 8. 상태 전이 규칙 (요약)

- `decision`: `created -> proposed -> scored -> voted -> finalized`
- `experiment`: `defined -> running -> observing -> stopped -> reported`
- `trpg`: `scene_started -> action_submitted -> resolved -> ticked -> scene_ended`
- `keeper`: `active -> reflected -> compacted? -> handoff_ready?`

## 9. 버전 규칙

- `protocol` 필드에 major/minor를 박는다. 예: `masc.game-view/0.1`
- minor는 backward compatible only
- major가 바뀌면 브리지 어댑터 없이는 혼용 금지

## 10. 구현 체크리스트 (다른 세션용)

- 공통 envelope 파서부터 구현
- `type/domain/name` 라우터 분리
- 도메인별 payload validator 추가
- idempotency_key 기반 중복 처리 추가
- verifier 결과를 command pipeline에 강제
- 상태 스냅샷(`state`)과 이벤트(`event`)를 분리 저장

## 11. 예상 기반 자동 행동 규칙 (If-Then)

- If `repetition_risk >= 0.7` Then `keeper.reflect`를 즉시 실행하고 다음 응답을 요약형으로 강제한다.
- If `goal_alignment_score < 0.6` Then `keeper.plan`으로 단기/중기/장기 목표를 재정렬하고 액션 전 `decision.finalize`를 강제한다.
- If `context_ratio >= 0.75` Then `keeper.compaction.check`를 우선 실행하고 high-cost 액션을 잠시 보류한다.
- If `context_ratio >= handoff_threshold` And `continuity_score >= 0.7` Then `keeper.handoff.check` 후 즉시 handoff를 수행한다.
- If `decision.finalize`가 없는데 `experiment.start` 또는 `trpg.action.submit` 요청이 오면 Then `error`(`PRECONDITION_REQUIRED`)를 반환한다.
- If verifier 결과가 `FAIL` Then 액션 실행을 중단하고 `decision.propose` 단계로 되돌린다.
- If verifier 결과가 `WARN` Then `risk_ack` 필드를 필수로 받고 실행한다.
- If `experiment`에서 부작용 지표가 guardrail 임계값 초과 Then 즉시 `experiment.stop` 이벤트를 발행한다.
- If 동일 `idempotency_key`가 재수신되면 Then 이전 `result`를 재반환하고 상태 변경을 금지한다.
- If 3턴 연속으로 실질 진척 이벤트가 없으면 Then `keeper.reflect` + `decision.create` 재정의를 자동 실행한다.

## 12. 에이전트 지시문 템플릿 (다른 세션에서 그대로 사용)

```text
[SYSTEM POLICY]
1) 항상 목표를 단기/중기/장기로 분리해 상태에 유지하라.
2) 행동 전에는 의사결정 게이트(decision.finalize)와 verifier 게이트를 통과시켜라.
3) 반복 발화 위험이 높으면 길이를 줄이고, 자기성찰 결과를 먼저 반영하라.
4) 컨텍스트 압력이 높으면 compaction/handoff를 우선하고 새 작업 추가를 늦춰라.
5) 상태 변경은 반드시 protocol envelope + idempotency_key로 기록하라.
```

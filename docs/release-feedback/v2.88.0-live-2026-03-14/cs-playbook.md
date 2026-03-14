# CS 플레이북

Date: 2026-03-14
Target: live MCP `2.88.0`

## 운영 원칙

- 먼저 live `/health` 기준 버전을 확인한다.
- read-path 이슈와 execution 이슈를 분리해서 본다.
- 사용자에게는 `worker`, `delegate`, `proof`, `dashboard` 같은 public surface 용어만 쓴다.

## 문의 1: "버전은 지금 몇이에요?"

### 답변 기준

- 기본 기준은 `http://127.0.0.1:8935/health`
- 현재 관찰값: `2.88.0`

### 응답 초안

- "현재 live service 기준 버전은 `2.88.0` 입니다."
- "이 버전에서는 `/health` 와 `agent_card` 표기가 일치합니다."

## 문의 2: "대시보드 current 가 이제 정상인가요?"

### 증상

- current dashboard 요약을 읽고 싶다

### 현재 답변

- "이전처럼 즉시 lock error가 아니라 compact summary가 반환됩니다."
- "다만 상세 조사에는 여전히 proof/events 교차 확인을 권장합니다."

### Escalation 기준

- 다시 distributed lock error가 반복적으로 발생

## 문의 3: "단일 worker 코딩은 쓸 만한가요?"

### 현재 판단

- 예. 가장 추천 가능한 경로다.

### 응답 초안

- "단일 worker + blocking + proof 확인 조합은 현재 권장 경로입니다."
- "작업 범위를 작게 유지할수록 안정적입니다."

## 문의 4: "여러 worker를 순차로 붙이면 되나요?"

### 현재 판단

- 이전보다 낫지만 아직 실험적이다.

### 실제 관찰

- implementer patch는 성공
- verifier 전용 worker는 `Max turns exceeded` 로 실패 가능

### 응답 초안

- "순차 multi-worker는 가능하지만 아직 완전히 안정적이지 않습니다."
- "최종 성공은 verifier 답변만 보지 말고 proof와 산출물 검증도 함께 확인해 주세요."

### 현재 우회

- 검증까지 한 worker가 끝내거나
- verifier worker를 쓰더라도 최종 판정은 실제 `check.py` 결과와 proof로 확인

## 문의 5: "batch spawn 후 바로 delegate 되나요?"

### 현재 판단

- 아직 아니다.

### 실제 관찰

- batch 응답에 `ready:false`
- 후속 delegate는 `not ready for delegation yet` 에러

### 응답 초안

- "현재 batch worker는 수락과 ready 상태가 분리되어 있습니다."
- "성공적인 spawn event나 ready 상태가 확인되기 전에는 follow-up delegate를 붙이지 않는 것이 좋습니다."

### 현재 우회

- batch 대신 순차 spawn
- 또는 ready state 관찰 후 delegate

## 문의 6: "왜 검증 worker가 끝까지 못 가죠?"

### 대표 증상

- `Max turns exceeded`

### 해석

- task는 실제로 해결됐을 수 있지만, 검증 전용 worker가 제한된 turn budget 안에서 마무리하지 못하는 경우가 있다.

### 현재 우회

- 검증 지시를 더 짧게 만든다.
- verifier를 별도 worker로 두지 않고 implementer가 최종 검증까지 맡는다.

### Escalation 기준

- 짧은 검증 prompt에서도 반복 실패
- proof/event 상에서 실패 원인이 불명확

## 지원팀용 한 줄 요약

- "`2.88.0` 에서는 버전 표기와 dashboard current 는 좋아졌습니다."
- "단일 worker 코딩은 권장, 순차 multi-worker는 실험적, batch 후 즉시 delegate는 아직 비권장입니다."

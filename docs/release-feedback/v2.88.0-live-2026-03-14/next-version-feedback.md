# 다음 버전 피드백

Date: 2026-03-14
Basis: live `2.88.0` + disposable sidecar reproductions

## Summary

`2.88.0` 에서는 read-path와 version truth가 실제로 좋아졌다. 다음 버전의 초점은 이제 “보이는 진실”보다 “협업의 안정성”으로 옮겨야 한다.

## Fixed in 2.88.0

- `agent_card` version이 `2.88.0` 으로 sync 되었다.
- live `dashboard current` 가 compact summary를 반환한다.

## P0

### P0-1. Ready-to-Delegate Contract

- 사용자 증상: batch spawn은 accepted 이지만 follow-up delegate는 즉시 못 붙음
- 현재 상태: 에러 메시지는 정직해졌지만 end-to-end는 아직 안 됨
- 필요 변경:
  - accepted 와 ready 를 명확히 구분한 상태 모델 유지
  - ready 전환 이벤트를 표준 읽기 경로에서 쉽게 확인 가능하게 만들기
  - 가능하면 ready 이후 자동 delegate 또는 queueing 지원

### P0-2. Verifier Turn-Budget Reliability

- 사용자 증상: 독립 verifier worker가 `Max turns exceeded` 로 끝날 수 있음
- 현재 상태: implementer patch는 성공하지만 verifier가 실패해 협업 안정성이 낮음
- 필요 변경:
  - verifier role의 default max-turns / prompt scaffold 조정
  - verification 전용 path를 더 짧고 결정적으로 만들기

## P1

### P1-1. Sequential Multi-worker as a Supported Pattern

- 사용자 증상: sequential multi-worker를 써도 언제 성공/실패하는지 예측이 어려움
- 필요 변경:
  - recommended prompt templates 제공
  - role별 supported pattern 문서화
  - final proof에서 role별 성공/실패를 더 명시적으로 요약

### P1-2. Runtime Selection Transparency

- 사용자 증상: worker가 어떤 runtime/model을 실제로 썼는지 직관적으로 읽기 어려움
- 현재 상태: raw result에는 있지만 사용자/CS 입장에선 아직 파편적
- 필요 변경:
  - session status와 proof에 runtime/model summary를 더 전면 노출

## P2

### P2-1. Dashboard Deep Read Confidence

- 현재 상태: compact summary는 살아났지만 상세 read-path 신뢰도는 추가 확인 필요
- 필요 변경:
  - current scope에서 compact beyond 상세 drill-down도 안정화
  - operator/CS용 “read-only diagnosis bundle” 제공

### P2-2. Regression Guard For Version Truth

- 현재 상태: version mismatch는 고쳐졌지만 다시 깨질 수 있음
- 필요 변경:
  - `/health` 와 `agent_card` version sync regression test
  - release pipeline에서 metadata parity check

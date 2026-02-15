# TRPG Development Plan (MVP -> v0.1)

Status: execution plan  
Updated: 2026-02-15

## Goal

`MASC`는 범용 에이전트 엔진으로 유지하고, 별도 `TRPG Engine`에서 DM/플레이어 진행과 사회실험을 운영한다.

## Milestones

## M0. Contracts and Tooling (done)

- [x] 아키텍처 블루프린트
- [x] 실험 플레이북 3종
- [x] 시나리오 JSON 계약
- [x] API 초안(OpenAPI)

## M1. Engine Core (in progress)

- [x] 도메인 타입(`phase`, `room_state`, `event`)
- [x] 상태머신(phase transition + turn rotation)
- [x] 이벤트 append-only 저장소
- [x] 스냅샷 기반 복구
- [x] RuleModule 인터페이스 + `dnd5e-lite` 기본 구현
- [x] 이벤트 리플레이 기반 상태 도출기

Verification:

- 상태 전이 단위테스트
- turn 순환 테스트
- 복구 리플레이 테스트
- dnd5e-lite 규칙 테스트(보너스/판정 티어/HP 이벤트 적용)

## Scope Cut (90% 채택 / 과잉 제외)

채택:

- 이벤트 소싱 중심 구조(append-only + replay)
- RuleModule 플러그인 분리(게임 규칙 교체 가능)
- 기존 `trpg-engine.py` 규칙을 기계적으로 포팅하는 접근

제외(현 단계 과잉):

- 별도 Python/FastAPI 신규 런타임 도입
- 초기부터 25개 파일 규모의 대규모 구조 분리
- MVP 이전에 풀 CRUD/운영 엔드포인트 일괄 구현

## M2. MASC Adapter

- [ ] keeper status 조회 어댑터
- [ ] keeper msg 송수신 어댑터
- [ ] timeout/retry/fallback 정책

Verification:

- keeper 1명 장애 주입 테스트
- timeout 시 `keeper.unavailable` 이벤트 확인

## M3. API and Stream

- [ ] REST endpoints(`/rooms`, `/state`, `/events`)
- [ ] SSE stream(`/rooms/{id}/stream`)
- [ ] human DM 입력(`/rooms/{id}/dm/input`)

Verification:

- curl 기반 E2E 스모크
- SSE 재연결 시 이벤트 연속성 검증

## M4. Viewer Integration

- [ ] TRPG 탭 상태 바인딩
- [ ] timeline + HUD + graph + metrics
- [ ] DM console (human mode)

Verification:

- round 진행 시 실시간 UI 갱신
- human DM 입력 -> turn 반영 확인

## M5. Experiment Harness

- [ ] negotiation/rumor/trust 3종 실행 하네스
- [ ] seed 고정 재현성 체크
- [ ] 결과 요약 리포트 생성

Verification:

- 시나리오별 5회 반복 실행
- 메트릭 변동 범위 기록

## Timeline (target)

1. M1: 1-2일
2. M2-M3: 2-3일
3. M4-M5: 2-3일

## Risks

- keeper 응답 지연으로 턴 정체
- Viewer가 엔진 이벤트보다 앞서 렌더링되는 race
- 실험 메트릭 계산과 원시 이벤트 정의 불일치

## Risk Mitigation

- timeout/fallback 정책을 M2에서 강제
- 이벤트 seq 기반 렌더링으로 정합성 유지
- 메트릭은 이벤트 리플레이 기반 재계산만 허용

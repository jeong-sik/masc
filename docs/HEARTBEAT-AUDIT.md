# Heartbeat Audit (Spec vs Implementation)

목적: Agent Heartbeat / Lodge Heartbeat의 스펙 대비 구현 차이를 정리하고, 고장 위험과 개선 목표를 명확히 한다.

## 핵심 요약

- **두 개의 heartbeat 시스템이 공존**하며, 역할과 생존 판정 대상이 다르다.
- **Room 생존 판정은 Agent Heartbeat 기준**이며, Lodge Heartbeat는 별개다.
- **이 PR에서 해결된 차이점**: leave/zombie 시 heartbeat stop, context 저장/ratio 계산, GraphQL auth header 정합성.

## Spec ↔ Implementation Gaps

| # | 항목 | 스펙/의도 | 구현 상태 | 영향/리스크 | 상태 |
|---|------|-----------|-----------|-------------|------|
| 1 | Agent vs Lodge Heartbeat 구분 | Agent Heartbeat는 Room 생존/컨텍스트, Lodge는 소셜/발견 | 문서에 명시 없음 | 운영자가 두 heartbeat를 동일하게 인식할 위험 | **문서화(이번 PR)** |
| 2 | leave 시 heartbeat 중지 | `leave`는 해당 agent heartbeat 정지 | 기존엔 heartbeat loop 잔존 가능 | 떠난 에이전트가 broadcast 지속 가능 | **수정(이번 PR)** |
| 3 | cleanup_zombies 시 heartbeat 중지 | zombie 정리 시 loop까지 정리 | 기존엔 loop 잔존 가능 | 좀비 정리 후에도 활동 지속 | **수정(이번 PR)** |
| 4 | Agent context report | heartbeat마다 context 보고 가능 | `masc_heartbeat`는 지원하지만 ratio 자동 계산 없음 | context 불완전/불일치 가능 | **수정(이번 PR)** |
| 5 | Lodge GraphQL 인증 헤더 | Bearer 토큰 사용 | 일부 코드가 `X-API-Key` | 401/데이터 미로딩 | **수정(이번 PR)** |
| 6 | Lodge enable flag 불일치 | 단일 플래그로 제어 | `LODGE_ENABLED` vs `LODGE_DAEMON_ENABLED` 혼재 | 설정 혼동/예상치 못한 동작 | **미해결(추가 개선 필요)** |
| 7 | Lodge self-heartbeat → Room 생존 | Lodge heartbeat가 Room last_seen 갱신 | 없음 | Lodge만 켜져도 Room에서는 좀비로 판정 | **의도 분리(문서화)** |

## 개선 목표 (Feedback Loop)

1. **정합성 목표**: Heartbeat 관련 플래그는 단일 소스로 통일 (`LODGE_ENABLED` 단일화 or 명확한 분리).
2. **운영 안정성 목표**: leave/zombie 시 heartbeat loop 0개 보장.
3. **컨텍스트 목표**: Agent Heartbeat에 context 보고 누락률 0% (ratio 자동 계산 포함).
4. **관찰 가능성 목표**: `masc_agents`/A2A 응답에 context 필드 포함, 상태 확인 가능.

## 추적 기준

- `Room.leave` 호출 후 `Heartbeat.list()`에서 해당 agent loop 0개
- `Room.cleanup_zombies` 실행 후 해당 agent loop 0개
- `masc_heartbeat` 호출 시 `agents`/`a2a_discover` 응답에 `context` 포함
- Lodge GraphQL 호출 시 Authorization Bearer 헤더 사용

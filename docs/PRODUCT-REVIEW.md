# MASC-MCP 제품 리뷰 (강하게)

## 결론 (요약)
- 현재 상태는 **로컬/신뢰 네트워크 전제의 개인용 협업 서버**로는 충분하다.
- **Internal Ops 제품**을 목표로 하면, **보안 기본값, API 계약, swarm proof 진실성**을 먼저 고정해야 한다.
- `/.well-known/agent-card.json` 와 `/metrics` 경로는 Eio 서버에 이미 존재한다. 현재 문제는 경로 부재가 아니라 **운영 기본값과 release gate**다.
- 실사용 기준에서 **즉시 막히는 P0**는 3가지다.

## P0 차단 요소
- hermetic required gate가 항상 초록이어야 한다. `make test`, `test_sse_storm_e2e`, contract harness 중 하나라도 깨지면 internal ops 제품 기준으로는 불합격이다.
- 인증/권한이 여전히 **opt-in strict mode** 중심이라서, 신뢰 네트워크 밖으로 나가는 순간 운영 기본값이 약하다.
- swarm proof artifact와 live read model이 어긋나면 operator가 같은 run을 두 개의 진실로 보게 된다.

## P1 위험 요소
- SSE 이벤트 타입이 **UI 기대값과 불일치**한다.
- REST API 스키마/버전 관리가 없다. (대시보드 통합 시 파손 위험)
- 메시지/태스크/에이전트 조회가 파일 전체 스캔 구조라 규모가 커지면 성능 저하.

## 제품 기능성 평가
- 작업 보드: 기능 범위 충분. (add/claim/done/transition)
- 협업 커뮤니케이션: broadcast/listen/portal A2A 제공. 실사용 가능.
- 워크스페이스: worktree, file lock 제공. 충돌 방지 실효.
- 운영 도구: 상태 조회, 비용 추적, 템포 제어 제공.
- MCP/JSON-RPC 호환: 스펙 충족, 다중 프로토콜 지원.

## 동작 가능성 평가
- 단일 머신/로컬 테스트는 안정적이다.
- 멀티머신은 Postgres 백엔드 전제이며 문서는 있으나, 운영 가이드/권한 통제가 약하다.
- 서버 재시작 및 세션 복구 흐름은 존재하지만, 일관된 운영 플레이북이 부족하다.

## 효율성 평가
- 읽기 경로가 파일 기반 스캔에 의존한다.
- 대시보드 REST는 전체 목록 반환이 기본값이다.
- SSE 버퍼 크기가 작아(100) 장시간 연결 시 유실 가능.

## 관측/운영성 평가
- Prometheus는 `/metrics`로 노출된다.
- Telemetry 기록 옵션은 존재하나, 외부 대시보드 연동 가이드 부족.

## 보안/권한 평가
- Auth 모듈은 존재하나 **서버 경로에 강제 적용되지 않는다**.
- REST/SSE/GraphQL은 인증 없이 접근 가능하다.
- 실사용에서 가장 큰 리스크다.

## 대시보드 통합 가능성 평가
- 통합은 가능하지만 **계약 정리와 보안/성능 개선이 선행**되어야 한다.
- 현재 웹 대시보드는 내부용이며, 외부 제품 통합용 스펙이 부재.

## 강제 개선안 (핵심)
- Auth 강제 적용: tools/call + REST/SSE/GraphQL의 non-local default를 strict로 수렴.
- REST 계약: limit/offset/filters, error schema, versioning.
- Swarm proof SSOT: canonical harness와 summary/live read model을 같은 pass 규칙으로 묶기.
- SSE 계약 정리: event type, payload schema 고정 + operator/warroom freshness 보강.

## 판단
- **개인/로컬 협업 제품으로는 합격.**
- **Internal Ops 운영 환경 기준으로는 개선 진행 중이지만 아직 보안 기본값과 API 계약이 남아 있다.**
- 다음 재평가 기준은 `required gates green + strict auth posture + truthful swarm proof`다.

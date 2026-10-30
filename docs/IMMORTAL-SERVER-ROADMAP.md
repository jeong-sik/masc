---
status: reference
---

# MASC 서버 감독 및 복구 구성

이 문서는 MASC 서버의 현재 감독·복구·종료 모듈과 아직 구현되지 않은 범위를 정리합니다.

## 현재 구현된 구성

- `lib/workspace/workspace_resilience.ml` — 시간 파싱과 관찰 헬퍼
- `lib/rate_limit.ml` — 요청 제한
- `lib/keeper/keeper_supervisor.ml` — Keeper 단위 실행 감독 (`Agent_core.Agent.run` 내부 턴 루프 자체는 `Runtime_agent`가 담당)
- `lib/dashboard/dashboard_harness_health.ml` — harness health 판정 원장
- `lib/fs_compat/capability_recovery_*.ml`, `publication_recovery_*.ml` — 기동 시 파일 스토어 정합성 검증 및 복구 (`mcp-server` `validate-stores`와 연동)
- `lib/shutdown.ml`, `lib/shutdown_hooks.ml` — SIGINT/SIGTERM 수신 시 단계별 graceful shutdown
- `lib/server/proactive_refresh.ml` — circuit breaker가 포함된 백그라운드 갱신 루프
- `lib/session.ml` (`restore_from_disk`) — 서버 재시작 시 세션 복구
- `lib/subsystem_health.ml` — 서브시스템별 liveness 상태 레지스트리 (`/health`의 `.scheduler.lag` 및 메모리 RSS 지표와 함께 노출)

## 미구현 범위 (Deferred)

[`ROADMAP.md`](../ROADMAP.md)의 Deferred 범위에 속하며 현재 스케줄되어 있지 않은 항목입니다.

- **프로세스 전체 Supervision Tree**: `lib/subsystem_health.ml`은 서브시스템의 종료 상태를 기록하지만, 죽은 내부 루프를 자동 재시작하는 상위 supervisor tree는 두지 않습니다.
- **무중단 코드 리로드 (Hot Reload)**: OCaml 바이너리 변경은 프로세스 재시작을 통해 적용합니다.
- **다중 노드 클러스터 모드 (Cluster Mode)**: 단일 작업 공간(`.masc/`)은 단일 서버 프로세스가 소유합니다.
- **Chaos 주입 프레임워크**: 별도의 자동 장애 주입 러너는 포함되어 있지 않습니다.

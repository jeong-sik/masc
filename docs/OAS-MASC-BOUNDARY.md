# OAS-MASC Boundary Contract

OAS (OCaml Agent SDK)와 MASC-MCP 사이의 역할 경계를 정의한다.

**원칙**: OAS는 MASC를 모른다. OAS의 변경은 모든 소비자에게 유익해야 한다.

```
Claude Code (consumer) → MASC-MCP (orchestration) → OAS (agent SDK)
```

## 역할 분리

| 관심사 | OAS (에이전트 수준) | MASC (조율 수준) |
|--------|---------------------|-------------------|
| 에이전트 실행 | `Agent.run`, turn loop | 스폰, 모니터링, 종료 결정 |
| 도구 타입 | `Tool.t`, `tool_result` | `Tool.create`로 MASC 도구 생성, OAS 네이티브 타입 직접 사용 |
| 단일 에이전트 상태 | `Checkpoint`, `Session`, `Context` | OAS 프리미티브 사용 (Phase 3+) |
| 조율 상태 | 해당 없음 | Board, tasks, room, PostgreSQL |
| 작업 메모리 | `Context` (scoped KV) | `Context_manager` (3-tier). Tier 1이 OAS Context 래핑 예정 |
| 장기 메모리 | 해당 없음 | PostgreSQL, Neo4j, pgvector |
| LLM 호출 | `Api`, `Provider` | `Llm_client` (프로세스 기반, curl) |
| 멀티에이전트 | `Orchestrator`, `Event_bus` | Rooms, broadcasts, scheduling, voting |
| 계승 | `Handoff` (LLM 결정) | `Succession` (컨텍스트 기반 DNA) |
| 사회성 | 해당 없음 | Board, Lodge, Gardener, Sentinel |
| 관찰 가능성 | `Event_bus`, `Raw_trace` | SSE, Dashboard, Prometheus |

## 의존 방향

```
MASC ──depends on──→ OAS
MASC ──does NOT──→ modify OAS
OAS  ──does NOT──→ know about MASC
```

- MASC는 OAS의 공개 API(`agent_sdk.mli`)만 사용한다.
- OAS 내부 타입이 변경되면 MASC가 따라간다 (OAS 네이티브 타입 직접 사용).
- OAS에 MASC 전용 기능을 추가하지 않는다.

## 통합 로드맵

| Phase | 내용 | OAS 모듈 | MASC 모듈 | 상태 |
|-------|------|----------|-----------|------|
| 1 | CI 복구 + 타입 호환 | `Types.tool_result` | `agent_swarm_*` | 완료 |
| 2 | 경계 문서 | - | 이 문서 | 완료 |
| 3 | Context 연결 | `Context.t`, `Context_reducer` | `Context_manager` | 진행 중 |
| 4 | Event_bus 브리지 | `Event_bus.Custom` | `Oas_events` | 계획 |
| 5 | Checkpoint 통합 | `Checkpoint`, `Checkpoint_store` | 인라인 (`perpetual_loop.ml` / `perpetual_oas.ml`) | 완료 |

### Oas_compat 제거 (v2.95.1)

`Oas_compat` 어댑터 모듈을 제거했다. OAS v0.24.0의 `tool_result` 타입을 MASC에서 직접 사용한다.
production 코드에서 호출이 없었으므로 (re-export만 존재) 영향 범위는 테스트 코드에 한정되었다.

## 결정 근거

| 결정 | 근거 |
|------|------|
| OAS Context를 Tier 1 저장소로 | 구조화된 scoped KV가 flat message list보다 상태 관리에 적합 |
| Event_bus.Custom으로 소셜 이벤트 | OAS의 기존 pub/sub 인프라를 재사용, 커스텀 이벤트 확장 가능 |
| Checkpoint으로 perpetual loop 상태 | 원자적 파일 저장/복원이 이미 구현되어 있음 |
| Oas_compat 제거 | production 미사용 확인, OAS v0.24.0 네이티브 타입 직접 사용으로 전환 |

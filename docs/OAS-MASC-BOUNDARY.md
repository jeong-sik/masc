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
| 도구 타입 | `Tool.t`, `tool_result` | `Tool.create`로 MASC 도구 생성, `Oas_compat`로 타입 변환 |
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
- OAS 내부 타입이 변경되면 MASC가 따라간다 (`Oas_compat` 어댑터 사용).
- OAS에 MASC 전용 기능을 추가하지 않는다.

## 타입 어댑터 (`Oas_compat`)

OAS v0.23.0에서 `tool_result` 타입이 변경되었다:

```ocaml
(* OAS < 0.23: (string, string) result *)
(* OAS >= 0.23: (tool_output, tool_error) result *)

type tool_output = { content: string }
type tool_error = { message: string; recoverable: bool }
```

`Oas_compat` 모듈이 기존 MASC 코드의 `(string, string) result`를 새 타입으로 변환한다:

| 함수 | 용도 |
|------|------|
| `tool_ok` | `string -> Ok { content }` |
| `tool_error` | `string -> Error { message; recoverable }` |
| `adapt_result` | `(string, string) result -> tool_result` |

## 통합 로드맵

| Phase | 내용 | OAS 모듈 | MASC 모듈 | 상태 |
|-------|------|----------|-----------|------|
| 1 | CI 복구 + 타입 호환 | `Types.tool_result` | `Oas_compat`, `agent_swarm_*` | 완료 |
| 2 | 경계 문서 | - | 이 문서 | 완료 |
| 3 | Context 연결 | `Context.t` | `Context_manager` | 계획 |
| 4 | Event_bus 브리지 | `Event_bus.Custom` | `Oas_events` | 계획 |
| 5 | Checkpoint 통합 | `Checkpoint`, `Checkpoint_store` | `Oas_checkpoint_bridge` | 계획 |

## 결정 근거

| 결정 | 근거 |
|------|------|
| OAS Context를 Tier 1 저장소로 | 구조화된 scoped KV가 flat message list보다 상태 관리에 적합 |
| Event_bus.Custom으로 소셜 이벤트 | OAS의 기존 pub/sub 인프라를 재사용, 커스텀 이벤트 확장 가능 |
| Checkpoint으로 perpetual loop 상태 | 원자적 파일 저장/복원이 이미 구현되어 있음 |
| adapt_result 어댑터 패턴 | 기존 코드 변경 최소화, 점진적 마이그레이션 가능 |

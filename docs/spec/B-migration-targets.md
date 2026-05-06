# Appendix B: Migration Targets

> 현재 상태(IS)와 목표 상태(SHOULD BE) 사이의 delta를 정의한다.
> 기준일: 2026-03-23

---

## 1. Current State Summary (v2.138.0)

| Metric | Value | Notes |
|--------|-------|-------|
| Version | v2.138.0 (dune-project), v2.137.0 (latest git tag) | Tag 1개 뒤처짐 |
| Language | OCaml 5.x + Eio | Structured concurrency |
| lib/ .ml + .mli files | 761 | 294개 flat lib/*.ml, 12개 sub-library |
| lib/ total LOC | ~194K | .ml + .mli 합산 |
| tool_*.ml modules | 125 | 일반적 MCP 서버: 3-10개 |
| MCP tool schemas | ~371 | 일반적 MCP 서버: 5-15개 |
| .mli files | 144 | 761개 중 19% |
| Test files | 319 | test/ 하위 |
| Sub-libraries | 11 | backend, bridge, core, dated_jsonl, eio_context, fs_compat, masc_log, process, room, time_compat, types |
| Flat lib/ .ml files | 294 | Sub-library에 속하지 않은 파일 |
| Environment variables | 50+ | 설정 파일 없이 env var만으로 운영 |
| Dashboard | Preact + HTM SPA | Vite 빌드, assets/dashboard/ |
| Transport | HTTP/1.1 (default), h2c (opt-in), WebSocket, WebRTC (experimental) | Multi-protocol |
| OAS integration | v0.87.0 delegation | Cascade, Memory, Swarm 일부 |
| Board backend | filesystem/JSONL | PostgreSQL runtime backend is not a target |

### 시스템 구성 비율 (LOC 기준, ARCHITECTURE-COMPLEXITY-ANALYSIS 발췌)

| Tier | Modules | Lines | 비율 |
|------|---------|-------|------|
| Tier 1: Core | 5 | ~1.5K | 4% |
| Tier 2: Production | 12 | ~8K | 23% |
| Tier 3: Extensions | 12 | ~8K | 23% |
| Tier 4: Experimental/Game | 18 | ~11K | 32% |
| Other (non-tool) | -- | ~6K | 18% |
| **Total tool code** | **47** | **~34.7K** | -- |

Core 기능(Tier 1)은 전체 tool 코드의 4%에 불과하다.
Tier 4 (Experimental/Game)가 32%를 차지하며, 이 코드는 coordination과 무관하다.

---

## 2. Architectural Debt

### 2.1 God Files

| File | Lines | Problem |
|------|-------|---------|
| `tool_trpg.ml` | 1,934 | Coordination과 무관. 별도 패키지 대상 |
| `tool_protocol_game_view.ml` | 1,674 | TRPG와 동일 |
| `tool_mdal.ml` | 1,092 | Metric loop 단독 모듈. 분리 가능 |
| `tool_risc.ml` | 1,070 | 실험 잔재 |
| `tool_llama.ml` | 1,052 | llama.cpp 런타임 관리. 별도 서비스 후보 |

### 2.2 Flat lib/ 구조

294개 .ml 파일이 lib/ 직하에 존재하고, 12개만 sub-library로 추출됨.
dune 모듈 수 579개는 일반적 MCP 서버(20-50)의 10배 이상이다.
Sub-library 추출 비율: 12/~300 = 4%.

### 2.3 Missing .mli

.mli 비율 19% (144/761). API 계약이 대부분 암묵적이다.
`docs/spec/` 작성으로 논리적 계약은 문서화하고 있으나, 컴파일러 수준 계약이 부족하다.

### 2.4 Circular Dependencies

`masc_mcp.ml` wrapper module이 모든 sub-library를 re-export하는 facade.
새 모듈 추가 시 masc_mcp.ml + lib/dune에서 additive conflict이 항상 발생한다 (memory: masc-mcp-module-conflict-hotspot).

### 2.5 Configuration Sprawl

50+ 환경변수가 `env_config.ml`과 개별 모듈에 분산.
Config file 체계 없이 env var만으로 운영하므로, 설정 발견성이 낮다.

---

## 3. Short-term Targets (v2.103-v2.104, ROADMAP 기준)

Source: `ROADMAP.md` Short-term + `ARCHITECTURE-COMPLEXITY-ANALYSIS.md` Phase 2-3

| Item | Module | Est. lines | Status | Priority |
|------|--------|-----------|--------|----------|
| TRPG + protocol_game_view -> `masc-games` | tool_trpg, tool_protocol_game_view | 3,600+ | Not started | High |
| risc + autoresearch + experiment -> `masc-experiments` | 3 tool modules | 2,700+ | Not started | High |
| dune optional library separation | dune, lib/ | -- | Not started | Medium |
| TRPG dm-keeper -> on-demand | keeper_autonomy | -- | Not started | Medium |
| Test noise cleanup: 32 duplicate files | test/ | ~12K lines | Audit done | Medium |
| 5 hollow test files 삭제 | test/ | -- | Pending | Low |

---

## 4. Mid-term Targets (v2.105-v2.108, 1-3 months)

Source: `ROADMAP.md` Mid-term

| Item | Source | Notes |
|------|--------|-------|
| Mode/profile system (core 5 / standard 17 / full 72) | ARCHITECTURE-COMPLEXITY Phase 3 | 기본 tool 노출을 5-17개로 제한 |
| Environment variables -> config file | ARCHITECTURE-COMPLEXITY Phase 3 | 50+ env vars 통합 |
| Binary distribution (brew/npm) | IDEAS #6 | Owner 없음 |
| Worktree diff broadcast | IDEAS #7 | Owner 없음 |
| Keeper Autonomy identity v2 Tier 1 | docs/archive/keeper-autonomy-identity-v2/ | 설계 완료, 구현 미착수 |

### Historical Mode/Profile Proposal

이 항목은 현재 tree에 없는 historical `MODE-SYSTEM` 설계 메모를 요약한 것이다.
즉시 구현 SSOT가 아니라 tool-discovery 축소 아이디어의 출처로만 읽는다.

| Profile | Tool count | 대상 |
|---------|-----------|------|
| Core | ~25 | 일반 에이전트 (join/claim/work/done) |
| Standard | ~70 | 운영자 에이전트 (keeper, operator) |
| Full | ~371 | 개발/디버깅 전용 |

이 전환만으로 에이전트의 tool discovery 부하를 93% 줄일 수 있다.

---

## 5. Long-term Direction (v2.109+, 3+ months)

Source: `ROADMAP.md` Long-term

| Direction | Trigger | Source |
|-----------|---------|--------|
| Keeper Autonomy identity v2 Tier 2-3 (ToM, archetypes) | Tier 1이 가치 증명 | docs/archive/keeper-autonomy-identity-v2/ |
| Figma-MCP 통합 (visual heartbeat) | figma-mcp 안정화 | — |
| Cluster mode / multi-node HA | 단일 노드 한계 도달 | IMMORTAL-SERVER-ROADMAP Phase 3 |
| Chaos engineering framework | Production 장애 패턴 확인 | IMMORTAL-SERVER-ROADMAP Phase 3 |
| Adaptive orchestration (dynamic org) | Agent 30+ | archive/IMPROVEMENT-PLAN P3 |

모두 "방향(direction)"이지 "약속(commitment)"이 아니다.
각각 trigger condition이 충족될 때만 활성화한다.

---

## 6. 7-Team Org Design

Source: memory/masc-org-design-7teams.md (2026-03-21)

327K LOC 모노리스를 7개 논리적 팀으로 분리하는 설계.
물리적 repo 분리가 아니라 sub-library + ownership boundary를 의미한다.

| Team | 범위 | 핵심 모듈 | 예상 LOC |
|------|------|----------|---------|
| **Foundation** | Types, Base, Config, Log | types/, core/, masc_log/, env_config | ~15K |
| **Room** | Room lifecycle, Task, Heartbeat, Board | room/, tool_room, tool_task, tool_heartbeat, board | ~20K |
| **Keeper** | Keeper runtime, Memory, Succession | keeper/, tool_keeper, agent_memory | ~25K |
| **Chain** | Cascade, OAS bridge, Swarm engine | cascade, oas_worker, chain, spawn | ~30K |
| **Server** | HTTP, MCP protocol, Transport, Auth | mcp_server_eio, transport, tool_auth | ~20K |
| **Dashboard** | Preact SPA, SSE bridge, API routes | dashboard/, web_dashboard | ~15K |
| **OAS Bridge** | OAS integration facade, Provider registry | oas_*, provider_registry | ~10K |

### 추출 순서 (8-Phase, 3-4주 예상)

1. Foundation (types, base, log) -- 의존 없는 leaf
2. Room (room lifecycle)
3. Keeper (keeper runtime)
4. Chain (cascade, spawn)
5. Server (transport, protocol)
6. Dashboard (frontend build pipeline 분리)
7. OAS Bridge (facade 정리)
8. Cleanup (masc_mcp.ml facade 축소, dead re-export 제거)

---

## 7. Module Extraction Plan

### 현재 Sub-library (11개)

```
lib/backend/     lib/bridge/      lib/core/       lib/dated_jsonl/
lib/eio_context/ lib/fs_compat/   lib/masc_log/   lib/process/
lib/room/        lib/time_compat/ lib/types/
```

### 즉시 추출 대상 (Phase 2 from ARCHITECTURE-COMPLEXITY)

| 새 패키지 | 포함 모듈 | Lines | 근거 |
|-----------|----------|-------|------|
| `masc-games` | tool_trpg, tool_protocol_game_view, trpg_*.ml | 3,600+ | Coordination과 완전 무관 |
| `masc-experiments` | tool_risc, tool_autoresearch, tool_experiment | 2,700+ | 실험 잔재, optional로 전환 |

### 구조 분할 대상

| 대상 | 현재 | 목표 | 설계 상태 |
|------|------|------|----------|
| lib/ flat files | 294개 | Sub-library 기반 조직 | 7-Team Design으로 매핑 완료 |
| masc_mcp.ml facade | 전체 re-export | Team별 facade | drift 문제 해소 필요 |

### .mli 추가 우선순위

| Module | Priority | 근거 |
|--------|----------|------|
| room.ml | High | Core lifecycle, 다른 모든 모듈이 의존 |
| cascade.ml | High | OAS bridge의 핵심 계약 |
| keeper_autonomy.ml | High | Keeper 자율 실행 계약 |
| spawn.ml | Medium | 61 references, Swarm 핵심 |

---

## 8. Test Hygiene

### 문제 요약

| Issue | Count | Source |
|-------|-------|--------|
| Duplicate/trivial coverage files | 32 | ROADMAP |
| Hollow test files (빈 테스트) | 4 | void, voice_stream, backend_eio, room_portal |
| Total test files | 319 | test/ 하위 |

### 32 Duplicate Coverage Files

test/ 디렉토리에 `*_coverage.ml` 파일이 32개 존재하며, 상당수가 원본 테스트와 중복이거나 stub만 포함한다.
이들은 ~12K LOC로, 실질적 테스트 가치 없이 빌드/CI 시간을 소모한다.

### 4 Hollow Tests

아래 파일은 빈 테스트(assert true 또는 테스트 본문 없음)로, 삭제 대상이다:

1. `test_void.ml`
2. `test_voice_stream.ml`
3. `test_backend_eio.ml`
4. `test_room_portal.ml`

---

## 9. Documentation Gaps

docs/spec/ 체계에서 아직 다루지 않는 영역.

| Gap | 현재 상태 | 필요한 spec |
|-----|----------|-------------|
| **Memory system** | 없음 (design draft removed 2026-04-17) | Memory tier 계약 (OAS 5-tier 포함) |
| **TRPG subsystem** | 7개 docs, 미통합 | 분리 패키지 후 자체 spec |
| **Transport protocol detail** | TRANSPORT-VERIFICATION-CHECKLIST (401 lines) | 09-server-transport.md에 부분 포함, WebRTC/WS 미상세 |
| **Keeper Autonomy identity** | docs/archive/keeper-autonomy-identity-v2/ (3 files) | 구현 후 spec 추가 |
| **OAS integration contract** | OAS-MASC-BOUNDARY.md (55 lines), oas-masc-state-boundary (278 lines) | OAS delegation 범위 상세화 |
| **Operational runbook** | COMMAND-PLANE-RUNBOOK, BENCHMARK-RUNBOOK | 운영 절차 통합 spec |
| **Config reference** | 없음 (env var 50+ 산재) | 환경변수/설정 SSOT |
| **Error catalog** | 없음 | MCP error code + 복구 절차 |
| **Migration guide** | 없음 (next-steps draft removed 2026-04-17) | 버전 간 breaking change + migration path |
| **Security model** | PRODUCT-REVIEW.md에서 지적 | Auth, trust boundary, threat model |

### docs/spec/ 현재 구성 (참고)

```
00-glossary.md              -- 용어집
01-system-overview.md       -- 시스템 개요
02-types-and-invariants.md  -- 타입과 불변식
03-room-coordination.md     -- Room 조율
04-chain-engine.md          -- Chain/Cascade 엔진
05-keeper-agent.md          -- Keeper 에이전트
06-command-plane.md         -- Command Plane
09-server-transport.md      -- 서버/전송
10-dashboard.md             -- Dashboard
11-board.md                 -- Board 시스템
A-existing-doc-index.md     -- (본 문서) 문서 색인
B-migration-targets.md      -- (본 문서) 마이그레이션 대상
SPEC-INDEX.md               -- Spec 목차
```

---

## Summary: Top 5 Migration Priorities

| # | Target | Impact | Effort |
|---|--------|--------|--------|
| 1 | masc-games + masc-experiments 패키지 분리 | Tier 4 코드 32% 격리 | Medium-High |
| 2 | Mode/profile system 구현 | 에이전트 tool 노출 93% 감소 | Medium |
| 3 | 32 duplicate test files 정리 | 빌드/CI 시간 절감, noise 제거 | Low |
| 4 | 5 hollow test files 삭제 | 테스트 noise 감소, 유지보수 단순화 | Low |
| 5 | Environment variables -> config file | 설정 발견성 및 운영성 개선 | Medium |

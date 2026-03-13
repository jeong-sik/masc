# masc-mcp Versioned Roadmap — Swarm Stability First

> Last updated: 2026-03-13
> Baseline: v2.86.0 (313 MCP tools, 579 OCaml modules, 645K lines)

## Context

masc-mcp v2.86.0, CI failure 존재, worktree ~200개 누적.
v2.86.1 패치 안정화 중.

**핵심 우선순위: Swarm이 안정적으로 돌아야 한다.**

Swarm 아키텍처는 건전하지만 **운영 guardrail이 부족**하다.
탐색 결과 6개 fragile point가 발견됨:

| # | Fragile Point | Risk | Location |
|---|---------------|------|----------|
| 1 | Provider 단일 장애점 (`:3034` only) | High | `agent_swarm_live_harness.ml` |
| 2 | Policy approval timeout 없음 → 작업 hang | High | CPv2 policy 모듈 |
| 3 | Dispatch tick 동시성 보호 없음 | Medium | `tool_command_plane_dispatch.ml` |
| 4 | Artifact 존재만 체크 (내용 검증 없음) | Medium | harness artifact persistence |
| 5 | Heartbeat 장기 drift → zombie agent | Medium | heartbeat daemon |
| 6 | Final marker 누락 시 silent success | Low | `agent_swarm_swarm.ml` |

## Cross-Reference (기존 로드맵 문서)

이 문서는 아래 3개 기존 로드맵의 항목을 우선순위 순으로 재배치한 통합 뷰다.
기존 문서는 상세 참조용으로 유지.

| 기존 문서 | 역할 | 이 로드맵 내 위치 |
|-----------|------|------------------|
| `docs/RELEASE-ROADMAP.md` | v2.86.1 안정화 | Milestone 1 |
| `docs/IMPROVEMENT-PLAN-2026-01.md` | 안정성 개선 (P1~P3) | Milestone 2~4 |
| `docs/IMMORTAL-SERVER-ROADMAP.md` | 고가용성 (Phase 1~3) | Milestone 5, 7 |

---

## Milestone 1: v2.86.1 — "Green Main" (즉시)

main을 green으로 복원. 이후 Swarm 작업의 전제 조건.

| Task | Priority | Effort |
|------|----------|--------|
| CI failure 해소 (main) | P0 | 1-2h |
| CHANGELOG v2.86.0 TBD 항목 채우기 | P0 | 30m |
| Worktree 정리 (~200 → <15) | P1 | 1h |
| Version bump 2.86.1 | P1 | 5m |

**상세**: `docs/RELEASE-ROADMAP.md`

**Exit Criteria**:
- `gh run list --branch main -L 5` 전부 success
- `git worktree list | wc -l` < 15
- CHANGELOG에 TBD 없음

---

## Milestone 2: v2.87.x — "Swarm Guardrails" (1-2주)

Swarm의 가장 위험한 fragile point 4개를 해소.

### 2-1. Provider Fallback Chain (Risk #1)

현재 live harness가 `:3034` 단일 endpoint에 의존.
Provider crash → 12-agent 전체 실패.

| Task | Detail |
|------|--------|
| Provider SLO 계약 | smoke test baseline (<10s) 정의 |
| Fallback cascade 연결 | `llm_client.ml`의 기존 cascade를 harness에 연결 |
| Circuit breaker on provider | 연속 3회 실패 시 fallback 전환 |
| Preflight validation 강화 | health check 실패 시 runtime-doctor.json 생성 |

**Exit**: provider down 시 fallback으로 harness 계속 실행 (테스트 증명)

### 2-2. Policy Approval Timeout (Risk #2)

승인 대기 중 무한 hang 방지.

| Task | Detail |
|------|--------|
| Approval SLA timeout | 기본 5분, 설정 가능. 초과 시 auto-deny + broadcast |
| Pre-approved policy 지원 | swarm operation 시작 시 정책 사전 승인 옵션 |
| Queue depth alert | 승인 대기 >1건 시 broadcast 경고 |

**Exit**: approval 없이 5분 경과 → auto-deny + 로그 (테스트 증명)

### 2-3. Dispatch Tick Serialization (Risk #3)

동시 tick 호출 시 JSONL 상태 파일 corruption 방지.

| Task | Detail |
|------|--------|
| File lock 또는 Eio.Mutex | `.masc/dispatch.lock` 기반 직렬화 |
| Concurrent tick detection | 두 번째 tick 시도 시 경고 반환 |

**Exit**: 동시 tick 2개 → 1개만 실행, 다른 하나는 경고 반환 (테스트 증명)

### 2-4. Artifact Content Validation (Risk #4)

존재 체크 → JSON 구조 + 필수 필드 검증.

| Task | Detail |
|------|--------|
| JSON parse 검증 | artifact 파일 read 후 `Yojson.Safe.from_string` 성공 확인 |
| Required fields 체크 | agent IDs, final_markers array 존재 확인 |
| Explicit failure | malformed artifact → 명확한 에러 메시지 |

**Exit**: corrupt JSON artifact → harness 명시적 실패 (테스트 증명)

---

## Milestone 3: v2.88.x — "Swarm Observability" (2-4주)

운영 중 문제를 **감지**할 수 있는 체계.

### 3-1. Heartbeat Monitoring (Risk #5)

| Task | Detail |
|------|--------|
| Heartbeat latency 수집 | broadcast timestamp 비교 |
| Zombie agent 탐지 | 연속 3회 miss → 자동 retire |
| Dashboard 표시 | agent 상태 + last heartbeat + drift 경고 |

### 3-2. Marker Handling (Risk #6)

| Task | Detail |
|------|--------|
| Assisted marker 명시 경고 | `final_marker_assisted=true` → broadcast 알림 |
| Marker format 유연화 | exact + 정규식 패턴 매칭 허용 |
| Swarm summary에 marker 통계 | 성공/실패/assisted 비율 |

### 3-3. Coverage Gate in CI

| Task | Detail |
|------|--------|
| bisect_ppx threshold | Swarm 관련 모듈 70%+ 필수 |
| CI job 추가 | coverage report + threshold warning |

**Exit Criteria**:
- zombie agent 탐지 후 자동 retire (테스트 증명)
- marker 누락 시 경고 broadcast (테스트 증명)
- CI coverage report 생성

---

## Milestone 4: v2.89.x — "Swarm Resilience" (4-8주)

Swarm이 **장애에서 복구**할 수 있는 체계.

| Task | Source | Detail |
|------|--------|--------|
| Automatic Checkpointing | IMPROVEMENT-PLAN 1.2 | ~400 LOC. swarm operation 중간 상태 저장 |
| Schema-based Message Validation | IMPROVEMENT-PLAN 1.1 | ~200 LOC. SSE 메시지 포맷 검증 |
| Lamport Timestamps | IMPROVEMENT-PLAN 2.2 | ~100 LOC. 메시지 순서 보장 |
| Keeper timeout 영속성 | WIP | 서버 재시작 시 keeper 상태 보존 |

**Exit Criteria**:
- swarm crash → restart → checkpoint에서 재개 (테스트 증명)
- 순서 역전 메시지 탐지 + 경고 (테스트 증명)

---

## Milestone 5: v2.90.x — "Immortal Server P1" (8-12주)

Swarm 안정성 확보 후, 서버 자체의 HA.

| Task | Source | Effort |
|------|--------|--------|
| Supervision Tree | IMMORTAL P1.1 | 2-3d |
| Health Check System | IMMORTAL P1.2 | 1d |
| Graceful Shutdown | IMMORTAL P1.3 | 1d |
| Judge Agent Pattern | IMPROVEMENT-PLAN 2.1 | ~250 LOC |

**상세**: `docs/IMMORTAL-SERVER-ROADMAP.md` Phase 1

**Exit Criteria**:
- `curl :8935/health` → 컴포넌트별 상태 반환
- SIGTERM → 진행 중 swarm 완료 후 종료
- supervision crash → 자동 재시작

---

## Milestone 6: v2.91.x — "Graduate or Archive" (12-16주)

Tier 3 Experimental 도구의 Graduate/Archive 결정.

| Category | Tool Count | Criteria |
|----------|------------|---------|
| TRPG | 20 | 3개월 사용 0이면 archive |
| Voice | 11 | stub 유지면 도구 수 축소 |
| Autoresearch | 6 | 사이클 완주 기록으로 판단 |
| MDAL | 6 | skill 연동 실적 기준 |
| RISC | 21 | stable 확인 시 Tier 2 승격 + 문서화 |

**Exit**: 카테고리별 Graduate/Archive/Keep 결정 문서

---

## Milestone 7: v2.92.x+ — "Immortal P2 + Architecture"

| Task | Source |
|------|--------|
| Auto Recovery (exponential backoff) | IMMORTAL P2.1 |
| Circuit Breaker (Closed/Open/HalfOpen) | IMMORTAL P2.2 |
| State Persistence (checkpoint 기반 복구) | IMMORTAL P2.3 |
| Chain partial rollback | WIP |
| Board JSONL → PG migration | WIP |

**상세**: `docs/IMMORTAL-SERVER-ROADMAP.md` Phase 2

**v3.0 진입 조건**: public MCP schema 변경이 필요할 때.

---

## Summary

```
v2.86.1  Green Main          즉시      CI fix, CHANGELOG, worktree cleanup
v2.87.x  Swarm Guardrails    1-2주     Provider fallback, Policy timeout, Tick lock, Artifact validation
v2.88.x  Swarm Observability 2-4주     Heartbeat monitoring, Marker handling, Coverage gate
v2.89.x  Swarm Resilience    4-8주     Checkpointing, Schema validation, Lamport, Keeper persistence
v2.90.x  Immortal P1         8-12주    Supervision, Health, Graceful shutdown
v2.91.x  Graduate/Archive    12-16주   Experimental tier 결정
v2.92.x+ Immortal P2         16주+     Auto recovery, Circuit breaker, State persistence
```

Swarm 안정성 (v2.87~v2.89)이 전체 로드맵의 60%를 차지.
HA/Immortal은 Swarm이 안정된 후에만 의미가 있다.

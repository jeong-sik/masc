# MASC→OAS Migration — Next Steps

v2.119.0 기준. Phase 0-3 완료, Phase 2.7 + Phase 4 남음.

## 완료된 작업 (v2.118.0)

| Phase | 내용 | PR |
|-------|------|----|
| 0 | 616파일 감사, 분류 (485/131), OAS Issues 8건, TRPG 아카이브 | #1668 |
| 1 | oas_worker.ml 템플릿, tool_mitosis_oas(-68%), tool_council_oas(-70%), 25 tests | #1668 |
| 2 | dashboard_proof(-71%), keeper_alerting(skill routing 분리), keeper_turn(-86%), schemas split, autoresearch split | #1683 |
| 3 | Random.int 40→0(ID gen), Env_config 8개 외부화, silent default 18개 Log.debug | #1699 |
| — | OAS dispatch switchover (mitosis + council → _oas 버전), message field fix | #1717 |

## 현재 수치

| 지표 | 시작 | 현재 | 목표 |
|------|------|------|------|
| LOC | 218K | ~197K | <100K |
| God files (850+) | 31 | ~26 | <10 |
| Random.int (ID gen) | 40 | 0 | 0 |

## 남은 작업

### 1. Gardener → OAS Worker 전환 (P1, 가장 긴급)

**문제**: Gardener가 keeper-style 에이전트를 스폰하지만, 스폰된 에이전트가 tool 없이 heartbeat만 보내는 좀비 상태.
- `qa-harness-drift`: turns=0, model=none, cost=$0
- `qa-ui-smoke`: turns=0, model=none, cost=$0
- `qa-surface-consistency`: turns=0, model=none, cost=$0

**해결**:
```
현재: Gardener → spawn Keeper → heartbeat loop → idle forever
목표: Gardener → Oas_worker.run(goal, tools) → 실행 → 결과 → 종료
```

**구현**:
1. `lib/gardener/gardener_decisions.ml`에서 spawn 경로를 `Oas_worker.run_with_masc_tools`로 변경
2. 1회성 worker는 goal 완료 후 자동 종료 (keeper loop 불필요)
3. 필요 시 Gardener가 주기적으로 재스폰 (cron-style)
4. OAS Event_bus로 결과를 dashboard에 전달

**검증**: 스폰된 에이전트가 turns > 0, cost > 0이면 성공.

### 2. P2.7: team_session → OAS Swarm (가장 큰 작업)

**규모**: 20파일, 9,984 LOC, 15개 외부 의존 모듈

**3단계 접근**:

#### 단계 1: Types 공유 인터페이스
- `team_session_types.ml` (652줄) + `team_session_types_enums.ml` (465줄)을 OAS Swarm과 호환되는 인터페이스로 정리
- `Swarm_types.swarm_config`와 `Team_session_types.session_config`의 교집합 정의

#### 단계 2: Engine 교체
- `team_session_engine_eio.ml` (723줄) → OAS `Swarm_runner.run` 위임
- `team_session_engine_helpers.ml` (564줄) → OAS convergence loop
- `team_session_engine_policy.ml` (426줄) → OAS agent selection strategy
- `team_session_engine_status.ml` (560줄) → OAS Event_bus 기반 상태 추적

#### 단계 3: Tool 어댑터
- `tool_team_session_step.ml` (857줄) → `Oas_worker` 경유
- `tool_team_session_routing.ml` (751줄) → OAS Swarm fiber 스케줄링
- 나머지 8개 `tool_team_session_*.ml` 파일 정규화

**의존 모듈 업데이트**:
- `swarm/swarm_status_parse.ml` — Team_session_types 참조
- `operator/operator_control.ml` — team session 상태 조회
- `dashboard/` — session 표시
- `worker_oas.ml` — 이미 OAS adapter (확장점)

### 3. Phase 3 잔여: 활성 도구 정규화

**목표**: 활성 ~100개 도구를 `oas_worker` 경유로 표준화.

**접근**: 카테고리별 배치 (10개씩)
1. Keeper 도구 (40개) — keeper_turn_msg_pipeline이 이미 OAS 경로 사용
2. Lodge 도구 (21개) — deprecated, OAS worker로 전환 또는 제거
3. Command Plane 도구 (16개) — CPv2 direct 경로 유지, OAS 래퍼
4. Team Session 도구 (11개) — P2.7과 동시 진행
5. Dashboard/Agent/Misc 도구 (나머지) — 개별 평가

### 4. Phase 4: 정리 + 문서화

1. **미사용 모듈 최종 삭제**: `reports/migration-classification-*.tsv`의 "archive" 131개 중 미삭제 파일
2. **전 public 모듈 .mli**: 현재 부분적 → 모든 public 모듈에 API 계약
3. **L1/L2/L3 경계 ADR**: OAS(L1 Agent Runtime + L2 Swarm) vs MASC(L3 Coordination) 경계 문서화
4. **벤치마크**: 빌드 시간, 바이너리 크기, LOC 최종 측정

### 5. OAS 이슈 (jeong-sik/oas)

| # | 우선순위 | 제목 | 상태 |
|---|---------|------|------|
| #197 | P1 | Checkpoint.t working_context | Open |
| #198 | P1 | Hook Error variant | Open |
| #199 | P2 | Event_bus topic subscription | Open |
| #200 | P2 | Swarm resource constraint | Open |
| #201 | P2 | message type convergence | Open |
| #202 | P3 | Pluggable agent selection | Open |
| #203 | P3 | Stateful tool pattern | Open |
| #204 | P3 | Config externalization | Open |

P1 (#197, #198)은 workaround(이중 저장, Event_bus bridge)로 동작 중이지만, 근본 해결이 필요.

## 실행 순서 권장

```
1. Gardener → OAS Worker (1-2일)     ← 가장 시급, 좀비 해소
2. OAS P1 이슈 해결 (#197, #198)     ← Phase 4 전 필요
3. P2.7 team_session 단계 1 (Types)  ← 1주
4. P2.7 team_session 단계 2 (Engine) ← 2주
5. P2.7 team_session 단계 3 (Tools)  ← 1주
6. Phase 3 잔여 (도구 정규화)         ← 2주
7. Phase 4 정리                       ← 1주
```

## 핵심 파일 참조

| 파일 | 역할 |
|------|------|
| `lib/oas_worker.ml` | OAS Agent 통합 템플릿 (200 LOC) |
| `lib/tool_mitosis_oas.ml` | OAS 기반 mitosis (351 LOC) |
| `lib/tool_council_oas.ml` | OAS 기반 council (321 LOC) |
| `lib/mcp_server_eio_execute.ml:427-454` | Dispatch switchover 지점 |
| `lib/gardener/gardener_decisions.ml` | Gardener spawn 로직 (전환 대상) |
| `lib/worker_oas.ml` | OAS adapter (기존, 401 LOC) |
| `reports/magic-numbers-audit.txt` | 매직넘버 감사 (~90건) |
| `reports/silent-defaults-audit.txt` | Silent default 감사 (697건) |

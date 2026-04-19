---
status: reference
last_verified: 2026-04-17
code_refs:
  - test/
  - lib/eval_gate.ml
  - lib/eval_harness.ml
---

# Testing

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Foundation |
| Maps to | `test/`, `lib/eval_gate.ml`, `lib/eval_harness.ml`, `lib/trajectory.ml`, `lib/verifier_core.ml`, `lib/verifier_oas.ml`, `lib/keeper/keeper_guards.ml` |
| Dependencies | (all subsystem specs) |
| Test Files | 319 (.ml), 6 (bench), 3 (fixtures/other) |

---

## 1. 목적

MASC MCP의 검증 전략을 정의한다. 테스트는 3개 계층(Hermetic Required, Optional Env-Gated, Manual Experiment)으로 분리되며, Keeper 에이전트에 대해서는 별도의 Eval Harness(시나리오 기반 행동 평가)를 운영한다.

---

## 2. 검증 철학

### 2.1 원칙

1. **Hermetic first**: 외부 DB, 네트워크, LLM 런타임 없이 재현 가능한 테스트가 CI 필수 게이트.
2. **Env-gated 분리**: PostgreSQL, live network, local LLM 등 환경 의존 테스트는 별도 계층으로 분리. CI 기본 green과 동일시하지 않는다.
3. **실험은 실험**: benchmark, swarm proof, TRPG workload는 pass/fail이 아니라 proof artifact와 함께 해석한다.
4. **Anti-fake 검증**: `assert true` 같은 허위 테스트를 자동 탐지하고 점수화한다.
5. **Agent harness**: Keeper 에이전트의 행동 품질은 시나리오 기반 eval harness로 측정한다.

### 2.2 테스트 환경 격리

`test/dune`의 `(env)` 섹션이 테스트 환경을 강제 격리한다:

```
MASC_STORAGE_TYPE=filesystem     (파일시스템 백엔드 강제)
MASC_POSTGRES_URL=""             (PG 자동 감지 차단)
DATABASE_URL=""                  (PG cascade 차단)
SUPABASE_DB_URL=""               (Supabase 차단)
SB_PG_URL=""                     (SB PostgreSQL 차단)
GRAPHQL_API_KEY=""               (GraphQL API 비활성화)
ZAI_API_KEY=""                   (ZAI API 비활성화)
```

이 격리는 비결정적 외부 네트워크 호출을 단위 테스트에서 제거한다.

---

## 3. Verification Matrix (3 계층)

### 3.1 Layer 1: Hermetic Required

CI 필수 게이트. 외부 의존성 없이 재현 가능.

| 항목 | 실행 방법 | 범위 |
|------|----------|------|
| 단위/통합 테스트 묶음 | `dune test --root .` / `make test` | 40+ 테스트 바이너리 |
| SSE Storm E2E | `./_build/default/test/test_sse_storm_e2e.exe` | SSE reconnect 시나리오 |
| Contract Harness (3종) | `make test-contract` | Streamable HTTP, Team Session, Golden Path |

Contract harness는 서버가 이미 떠 있다고 가정하지 않고 hermetic bootstrap 경로로 실행된다.
`archive/trpg/scripts/` 아래의 game-view/TRPG 계약 스크립트는 현재 active contract suite가 아니라 archive/manual 검증으로 분류한다.

**판정 기준**: main 브랜치가 green이면 core MCP/HTTP/Team-Session 계약이 깨지지 않았다.

### 3.2 Layer 2: Optional Env-Gated

특정 환경이 있을 때만 의미가 있는 테스트. CI 기본 green에 포함되지 않는다.

| 게이트 | 테스트 파일 | 필요 환경 |
|--------|-----------|----------|
| PostgreSQL | `test_board_pg.ml`, `test_tool_mdal_pg.ml`, `test_pubsub_postgres.ml` | `MASC_POSTGRES_URL` |
| Live network | `test_ice_eio.ml`, `test_stun.ml` | 네트워크 접근 |
| Local viewer | `scripts/viewer-local-e2e-check.sh` | 빌드 도구 |

규칙: env 미설정 시 skip 또는 not run. CI 로그에 "왜 안 돌았는지"가 명시되어야 한다.

### 3.3 Layer 3: Manual Experiment

Correctness gate가 아닌 orchestration/benchmark/behavior 실험. Runbook과 함께 해석한다.

| 실험 | 스크립트 | 참조 문서 |
|------|---------|----------|
| Agent swarm proof | `scripts/harness_agent_swarm_live.sh` | `docs/BENCHMARK-RUNBOOK.md` |
| Supervised delivery | `scripts/harness_supervisor_team_session.sh` | `docs/SUPERVISOR-MODE.md` |
| TRPG smoke | `scripts/run_trpg_grimland_smoke.sh` | - |
| Local64 model matrix | `scripts/harness_local64_model_matrix.sh` | - |

규칙: proof artifact, report, runtime 전제, 모델 선택 근거를 함께 남긴다.

---

## 4. 테스트 파일 인벤토리

### 4.1 총계

| 카테고리 | 파일 수 | 비고 |
|---------|--------|------|
| `test_*.ml` (전체) | 313 | 단위/통합/E2E 혼합 |
| `bench_*.ml` | 6 | 성능 벤치마크 |
| `*_coverage.ml` | 100 | 커버리지 보강 테스트 |
| `*_e2e.ml` | 6 | 종단간 시나리오 |
| fixtures/ | 1 dir | 테스트 데이터 |
| 합계 | ~322 항목 | |

### 4.2 서브시스템별 분포

| 서브시스템 | 파일 수 | 대표 파일 |
|-----------|--------|----------|
| Tool (`test_tool_*`) | 64 | `test_tool_board.ml`, `test_tool_mdal.ml`, `test_tool_voice.ml` |
| Dashboard (`test_dashboard_*`) | 13 | `test_dashboard_cache.ml`, `test_dashboard_proof.ml` |
| Room (`test_room_*`) | 8 | `test_room.ml`, `test_room_coverage.ml` |
| Agent (`test_agent_*`) | 7 | `test_agent_identity.ml`, `test_agent_registry_eio.ml` |
| SSE (`test_sse_*`) | 7 | `test_sse.ml`, `test_sse_storm_e2e.ml`, `test_sse_qw.ml` |
| Keeper (`test_keeper_*`) | 6 | `test_keeper_memory.ml`, `test_keeper_unified.ml` |
| Chain (`test_chain_*`) | 6 | `test_chain_coverage.ml`, `test_chain_orchestrator_eio.ml` |
| Swarm (`test_swarm_*`) | 6 | `test_swarm.ml`, `test_swarm_checkpoint.ml` |
| Board (`test_board_*`) | 4 | `test_board_api_e2e.ml`, `test_board_pg.ml` |
| OAS (`test_oas_*`) | 3 | `test_oas_integration.ml`, `test_oas_worker.ml` |
| MDAL (`test_mdal_*`) | 3 | `test_mdal.ml`, `test_mdal_store.ml` |
| Worker (`test_worker_*`) | 3 | `test_worker_runtime.ml`, `test_worker_dev_tools.ml` |
| Verification (`test_verif*`) | 3 | `test_verifier_oas_bridge.ml` |
| Memory (`test_memory_*`) | 1 | `test_memory_oas_5tier.ml` |
| 기타 | ~50+ | auth, encryption, spawn, bounded, etc. |

### 4.3 dune 테스트 그룹

`test/dune`은 다음 구조로 테스트를 구성한다:

1. **Pure synchronous tests** (최대 묶음, `(tests ...)` 블록): 44개 테스트를 단일 `(libraries masc_mcp alcotest ...)` 의존으로 묶음
2. **Eio-dependent tests** (개별 `(test ...)` 블록): Eio.Mutex, Session.with_lock 등을 사용하는 테스트는 `eio eio_main` 의존으로 개별 빌드
3. **OAS bridge tests**: `agent_sdk` 의존
4. **Script tests**: CI/harness 스크립트의 동작을 검증하는 테스트 (`test_ci_hardening_source.ml`, `test_ci_run_tests_script.ml`)

---

## 5. Test Harness Architecture

### 5.1 Eval Gate (lib/eval_gate.ml)

Keeper tool call의 사전/사후 실행 게이트. Swiss Cheese Model (다중 방어층).

```
Tool call -> Cost budget check
          -> Destructive pattern detection
          -> Tool allowlist check
          -> Entropy check (동일 도구 N회 연속 호출)
          -> [모두 Pass] -> 실행 허용
          -> [하나라도 Reject] -> 실행 차단
```

**gate_config 기본값**:

| 파라미터 | 기본값 | 설명 |
|---------|--------|------|
| `max_cost_usd` | 0 | 세션 비용 한도 (`0`이면 비활성) |
| `max_tool_calls_per_turn` | 10 | 턴당 도구 호출 상한 |
| `entropy_threshold` | 3 | 동일 도구 연속 호출 임계값 |
| `destructive_check_enabled` | true | 파괴적 명령 탐지 |
| `allowlist_enabled` | false | 도구 허용 목록 사용 |

**Destructive patterns** (18개): `rm -rf`, `drop table`, `git push --force`, `chmod 777`, `mkfs`, `dd if=`, `shutdown` 등. 문자열 부분 매칭으로 탐지. AST 수준 파싱은 아니지만 일반적 패턴을 차단한다.

### 5.2 Eval Harness (lib/eval_harness.ml)

시나리오 기반 Keeper 행동 평가. METR Task Standard와 OpenAI Harness 패턴에서 영감.

**구성 요소**:

```
Scenario -> goal + setup_messages + tool_expectations + graders
Runner   -> 시나리오 실행, grader 적용, EvalResult 생산
Grader   -> Deterministic (Exact/Contains/Regex/NotContains)
         -> ModelBased (LLM 프롬프트 + rubric)
Metrics  -> pass@k, mean score, consistency
```

**Scenario 구조**:

```ocaml
type scenario = {
  id : string;                    (* 고유 식별자 *)
  category : string;              (* "safety" | "capability" | "efficiency" *)
  goal : string;                  (* Keeper에 주어지는 목표 *)
  tool_expectations : tool_expectation list;
  graders : grader list;
  max_turns : int;
  max_cost_usd : float;
  tags : string list;             (* "regression" | "smoke" 등 *)
}
```

**Grader 타입**:
- `Deterministic`: 필드(result/tool_name/error)에 대한 Exact/Contains/Regex/NotContains 매칭. 0 지연.
- `ModelBased`: LLM에 rubric과 결과를 제출하여 0.0-1.0 점수 산출. 비용 발생.

### 5.3 Anti-Fake (RETIRED)

`lib/anti_fake.ml`는 허위 테스트 패턴 감지(`assert true`, `let _ =`, `(* TODO *)` 등에 대한 자동 감점 + `score_result`/`audit_summary` 집계)를 제공하던 모듈이었고, #2848 dead-code sweep에서 `lib/agent_ecosystem`/`lib/agent_neo4j`와 함께 제거됐다 (`grep -rn anti_fake lib/ test/` → 0 hits).

현재는 `scripts/check-test-quality.sh`와 `eval_harness`의 trajectory-level assertion 검증이 그 역할을 부분 승계하며, 전용 테스트 품질 게이트는 노출되지 않는다.

### 5.4 Trajectory (lib/trajectory.ml)

Keeper tool call의 JSONL 기반 궤적 로깅. 결정적 재생, 비용 누적, 엔트로피 탐지, eval_harness 연동을 지원한다.

**기록 위치**: `.masc/trajectories/{keeper_name}/{trace_id}.jsonl`

**tool_call_entry 필드**:

| 필드 | 타입 | 설명 |
|------|------|------|
| `ts` | float | Unix 타임스탬프 |
| `turn` | int | 세션 내 턴 번호 |
| `round` | int | 턴 내 도구 라운드 (1-3) |
| `tool_name` | string | 호출된 도구 |
| `gate_decision` | Pass/Reject | 사전 게이트 결과 |
| `result` | string option | 실행 결과 (게이트 차단 시 None) |
| `duration_ms` | int | 실행 시간 |
| `cost_usd` | float | 추정 비용 |

**trajectory_outcome**: `Completed | Failed | Timeout | CostExceeded | Gated`.

### 5.5 Verifier (lib/verifier_core.ml, lib/verifier_oas.ml)

`lib/keeper/keeper_verifier.ml`가 단일 모듈로 제공하던 Generator–Verifier 루프는 `lib/verifier_core.ml`(코어 판정 로직)과 `lib/verifier_oas.ml`(OAS-bound execution path)로 2분할됐고, keeper 레벨의 사전 검증(guard gating)은 `lib/keeper/keeper_guards.ml`로 이동했다 (구 `keeper_verifier.ml`는 제거, #2589 및 05-keeper-agent 스펙 참조).

현 루프:

```
proposed_action -> verifier_core: risk_level 분류 (Safe/Moderate/Dangerous)
                                  + cost 추정
                                  + PASS / WARN / FAIL
              -> keeper_guards: execution-time guard (permission, rate, safety)
              -> verifier_oas: OAS execution path에서 재확인
```

### 5.6 Keeper Contract (RETIRED)

`lib/keeper/keeper_contract.ml`는 keeper 정책/런타임 enum의 typed 표현(예: `room_scope = Current | All (legacy)`)을 제공했고, single-room 통합 과정에서 `room_scope` 타입과 함께 제거됐다 (`grep -rn 'type room_scope' lib/` → 0 hits; 남은 `room_scope_*` 식별자는 캐시 helper 함수 이름일 뿐 타입 정의가 아님).

Keeper 관련 enum의 현재 typed boundary는 05-keeper-agent 스펙의 §2 module table을 따른다.

---

## 6. CI Pipeline

### 6.1 스크립트: scripts/ci-run-tests.sh

CI 테스트 실행기. 다음 기능을 제공한다:

| 기능 | 설명 |
|------|------|
| Heartbeat logging | `CI_TEST_HEARTBEAT_SEC` (기본 30초) 간격으로 진행 상태 출력. "silent hang" 방지. |
| Timeout | `CI_TEST_TIMEOUT_SEC` (기본 1200초). 초과 시 진단 덤프. |
| Diagnostics dump | 실패/타임아웃 시 프로세스 스냅샷, 로그 파일 경로, 빌드 디렉토리 정보 출력. |
| Clean retry | `CI_TEST_ALLOW_CLEAN_RETRY=1`이면 실패 시 clean build 후 재시도. |
| RPC retry | `CI_TEST_ALLOW_RPC_RETRY=1`이면 RPC 관련 실패 시 재시도. |
| Isolated build | `CI_TEST_ISOLATED_BUILD_DIR` (기본 `.ci_build`)로 격리 빌드 가능. |

### 6.2 실행 흐름

```bash
# 표준 CI 경로
make test                    # dune test --root .
make test-contract           # scripts/harness/contract/run_all.sh

# 수동 검증
dune exec _build/default/test/test_sse_storm_e2e.exe
MASC_POSTGRES_URL="..." dune exec _build/default/test/test_board_pg.exe
```

### 6.3 Contract Harness

| Contract | 파일 | 검증 대상 |
|----------|------|----------|
| Streamable HTTP | `streamable_http_contract.sh` | MCP Streamable HTTP transport 프로토콜 |
| Team Session | `team_session_contract.sh` | Team session start/step/finalize 계약 |
| Golden Path | `golden_path_1_contract.sh` | Room join -> task add -> claim -> transition 기본 경로 |

Contract harness는 hermetic bootstrap으로 실행된다. 사전 서버 실행을 요구하지 않는다.

---

## 7. Coverage

### 7.1 bisect_ppx

OCaml 코드 커버리지 도구. `BISECT_FILE` 환경변수로 출력 경로를 지정한다.

```bash
BISECT_FILE=$(pwd)/_coverage dune test --instrument-with bisect_ppx
bisect-ppx-report html --coverage-path _coverage
```

### 7.2 Coverage 파일 분포

100개의 `*_coverage.ml` 파일이 커버리지 보강 목적으로 존재한다. 이 파일들은 기존 테스트에서 누락된 경로를 보완하며, anti_fake 검증을 통과해야 한다.

---

## 8. 테스트 라이브러리 의존성

| 라이브러리 | 용도 |
|-----------|------|
| `alcotest` | 테스트 프레임워크 (assertion, test case 구조화) |
| `masc_mcp` | 서버 라이브러리 |
| `agent_sdk` | OAS 에이전트 SDK |
| `eio`, `eio_main` | Eio 동시성 (Mutex, 스케줄러) |
| `yojson` | JSON 직렬화/역직렬화 |
| `mirage-crypto`, `mirage-crypto-rng` | 암호화 테스트 |
| `cohttp` | HTTP 클라이언트 테스트 |
| `str` | 정규식 |

---

## 9. 불변식

- **INV-T1**: Hermetic Required 계층의 모든 테스트는 `MASC_POSTGRES_URL=""`, `GRAPHQL_API_KEY=""` 상태에서 통과해야 한다.
- **INV-T2**: Env-gated 테스트는 필수 환경변수 부재 시 skip 또는 not run으로 처리한다. 실패가 아니다.
- **INV-T3**: `eval_gate`의 각 검사 레이어는 독립적이다. 한 레이어의 통과가 다른 레이어의 실패를 가릴 수 없다 (Swiss Cheese).
- **INV-T4**: `trajectory.tool_call_entry`의 `gate_decision`이 `Reject`이면 `result`는 반드시 `None`이다.
- **INV-T5**: `anti_fake` penalty 패턴에 매칭되는 테스트 파일은 `quality_tier`에서 경고 또는 위험으로 분류된다.
- **INV-T6**: Contract harness는 외부 서버에 의존하지 않는다. Hermetic bootstrap 경로만 사용한다.
- **INV-T7**: `eval_harness` 시나리오의 `max_cost_usd`를 초과하면 `trajectory_outcome`은 `CostExceeded`이다.

---

## 10. 테스트 작성 가이드

### 10.1 새 테스트 추가 시

1. `test/dune`에 테스트 등록 (pure sync면 최상단 `(tests ...)` 블록, Eio 의존이면 개별 `(test ...)` 블록)
2. Hermetic required로 분류 가능한지 확인. 외부 의존이 있으면 env-gated 계층에 배치.
3. `assert true` 사용 금지. `Alcotest.check` 또는 의미 있는 assertion 사용.
4. 외부 서비스 mock은 테스트 내부에서 처리. `test/dune`의 env 격리에 의존.

### 10.2 Keeper 행동 테스트 추가 시

1. `eval_harness.scenario` 정의 (goal, tool_expectations, graders)
2. Deterministic grader를 우선 사용. LLM grader는 cost 고려.
3. `trajectory` 로깅으로 재현성 확보.
4. `eval_gate` 설정으로 안전 경계 지정.

---

## 11. References

| 문서 | 경로 |
|------|------|
| Verification matrix | `docs/VERIFICATION-MATRIX.md` |
| Check evaluation spec | `docs/design/check-evaluation-spec.md` |
| Contract-driven agent loop RFC | `docs/design/contract-driven-agent-loop-rfc.md` |

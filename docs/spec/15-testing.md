---
status: reference
last_verified: 2026-07-12
code_refs:
  - test/
  - lib/keeper/keeper_gate.ml
  - lib/keeper/keeper_approval_queue.ml
  - lib/eval_harness.ml
---

# Testing

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Foundation |
| Maps to | `test/`, `lib/keeper/keeper_gate.ml`, `lib/keeper/keeper_approval_queue.ml`, `lib/eval_harness.ml`, `lib/trajectory.ml`, `lib/verifier_core.ml`, `lib/verifier_oas.ml` |
| Dependencies | (all subsystem specs) |
| Test Files | `test/dune`와 포함 stanza가 SSOT |

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

**판정 기준**: main 브랜치가 green이면 core MCP/HTTP/keeper/operator 계약이 깨지지 않았다.

### 3.2 Layer 2: Optional Env-Gated

특정 환경이 있을 때만 의미가 있는 테스트. CI 기본 green에 포함되지 않는다.

| 게이트 | 테스트 파일 | 필요 환경 |
|--------|-----------|----------|
| Live network | `scripts/harness/transport/verify_webrtc_live_env.sh` | 네트워크 접근 |
| Local viewer | `scripts/viewer-local-e2e-check.sh` | 빌드 도구 |

규칙: env 미설정 시 skip 또는 not run. CI 로그에 "왜 안 돌았는지"가 명시되어야 한다.

### 3.3 Layer 3: Manual Experiment

Correctness gate가 아닌 orchestration/benchmark/behavior 실험. Runbook과 함께 해석한다.

| 실험 | 스크립트 | 참조 문서 |
|------|---------|----------|
| Keeper fleet proof | `scripts/harness/workload/agent_swarm_live.sh` | `docs/BENCHMARK-RUNBOOK.md` |
| Supervised delivery | - | `docs/SUPERVISOR-MODE.md` |
| TRPG smoke | `scripts/run_trpg_grimland_smoke.sh` | - |
| Local runtime capacity | `scripts/llama-runtime-pool.sh` | `docs/PERFORMANCE-SLO.md` |

규칙: proof artifact, report, runtime 전제, 모델 선택 근거를 함께 남긴다.

---

## 4. 테스트 파일 인벤토리

테스트 목록은 자주 변하므로 이 문서에 손관리 파일 수를 고정하지 않는다.
현재 목록은 repo에서 직접 생성한다.

```bash
rg --files test | sort
rg -n '^\((test|tests|executable)\b|^\s+\((name|names|modules)\b' test/dune test/*/dune
```

### 4.1 dune 테스트 그룹

`test/dune`은 다음 구조로 테스트를 구성한다:

1. **Pure synchronous tests** (최대 묶음, `(tests ...)` 블록): 44개 테스트를 단일 `(libraries masc alcotest ...)` 의존으로 묶음
2. **Eio-dependent tests** (개별 `(test ...)` 블록): Eio.Mutex, Session.with_lock 등을 사용하는 테스트는 `eio eio_main` 의존으로 개별 빌드
3. **OAS bridge tests**: `agent_sdk` 의존
4. **Script tests**: CI/harness 스크립트의 동작을 검증하는 테스트 (`test_ci_hardening_source.ml`, `test_ci_run_tests_script.ml`)

---

## 5. Test Harness Architecture

### 5.1 Keeper execution-boundary tests

Keeper 실행 테스트는 두 경계를 분리해서 검증한다.

- typed argv/input, 명시적 cwd/redirect target, allowed-path containment,
  sandbox confinement 같은 객관적 구조 불변식
- exact Always Allowed, configured LLM Auto Judge, non-blocking HITL로 구성된
  request-local Gate 흐름

명령 문자열, 도구 이름, 호출 횟수, cost, entropy를 로컬 권한 분류나
Keeper stop/pause 조건으로 사용하지 않는다. Cost, turn, tool-call 통계는
관측 및 평가 데이터일 뿐 실행 전 차단 근거가 아니다.

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

`lib/keeper/keeper_verifier.ml`가 단일 모듈로 제공하던 Generator–Verifier 루프는 `lib/verifier_core.ml`(코어 판정 로직)과 `lib/verifier_oas.ml`(OAS-bound execution path)로 2분할됐다. `pre_tool_use`는 시간 관측만 하며, 외부 효과 승인은 normalized Gate 경계에서 별도로 판정한다 (구 `keeper_verifier.ml`는 제거, #2589 및 05-keeper-agent 스펙 참조).

현 루프:

```
typed effect request -> objective structure/path/sandbox invariants
                     -> Gate: exact Always Allowed | configured LLM Auto Judge | non-blocking HITL
                     -> execution + observation

Task completion claim -> configured LLM verification
                      -> complete | remain active

cost / token / turn -> observation and aggregation only
```

### 5.6 Keeper Contract (RETIRED)

`lib/keeper/keeper_contract.ml`는 keeper 정책/런타임 enum의 typed 표현(예: workspace-targeting enum legacy variant)을 제공했고, single-workspace 통합 과정에서 해당 타입이 제거됐다 (`grep -rn 'type .*scope' lib/keeper` 기준 legacy scope enum hit 없음).

Keeper 관련 enum의 현재 typed boundary는 05-keeper-agent 스펙의 §2 module table을 따른다.

---

## 6. CI Pipeline

### 6.1 스크립트: scripts/ci-run-tests.sh

CI 테스트 실행기. 다음 기능을 제공한다:

| 기능 | 설명 |
|------|------|
| Heartbeat logging | `CI_TEST_HEARTBEAT_SEC` (기본 30초) 간격으로 진행 상태 출력. "silent hang" 방지. |
| Diagnostics dump | 실패 시 프로세스 스냅샷, 로그 파일 경로, 빌드 디렉토리 정보 출력. |
| Disk observation | 사용 가능 공간이 임계값 아래로 내려가면 상태와 진단을 기록하되 실행을 중단하지 않는다. |
| Single attempt | 명령을 정확히 한 번 실행하고 원래 종료 코드를 보존한다. 실행 경계는 CI job이 소유한다. |

### 6.2 실행 흐름

```bash
# 표준 CI 경로
make test                    # dune test --root .
make test-contract           # scripts/harness/contract/run_all.sh

# 수동 검증
scripts/dune-local.sh build ./test/test_sse_storm_e2e.exe
./_build/default/test/test_sse_storm_e2e.exe
```

### 6.3 Contract Harness

| Contract | 파일 | 검증 대상 |
|----------|------|----------|
| Streamable HTTP | `streamable_http_contract.sh` | MCP Streamable HTTP transport 프로토콜 |
| Golden Path | `golden_path_1_contract.sh` | Workspace join -> task add -> claim -> transition 기본 경로 |

Contract harness는 hermetic bootstrap으로 실행된다. 사전 서버 실행을 요구하지 않는다.

---

## 7. Coverage

100% coverage closeout uses the checklist in
`docs/qa/BISECT-COVERAGE-CLOSEOUT-RUNBOOK.md`. Do not close a coverage goal from
stale `_coverage` files or from the existence of `*_coverage.ml` supplement
tests alone.

### 7.1 bisect_ppx

OCaml 코드 커버리지 도구. `BISECT_FILE` 환경변수로 출력 경로를 지정한다.

```bash
scripts/coverage_percent.sh --fail-under 100
bisect-ppx-report html --coverage-path _coverage
```

### 7.2 Coverage 파일 분포

100개의 `*_coverage.ml` 파일이 커버리지 보강 목적으로 존재한다. 이 파일들은 기존 테스트에서 누락된 경로를 보완하며, anti_fake 검증을 통과해야 한다.

---

## 8. 테스트 라이브러리 의존성

| 라이브러리 | 용도 |
|-----------|------|
| `alcotest` | 테스트 프레임워크 (assertion, test case 구조화) |
| `masc` | 서버 라이브러리 |
| `agent_sdk` | OAS 에이전트 SDK |
| `eio`, `eio_main` | Eio 동시성 (Mutex, 스케줄러) |
| `yojson` | JSON 직렬화/역직렬화 |
| `mirage-crypto`, `mirage-crypto-rng` | 암호화 테스트 |
| `cohttp` | HTTP 클라이언트 테스트 |
| `str` | 정규식 |

---

## 9. 불변식

- **INV-T1**: Hermetic Required 계층의 모든 테스트는 외부 GraphQL/ZAI credentials 없이 통과해야 한다.
- **INV-T2**: Env-gated 테스트는 필수 환경변수 부재 시 skip 또는 not run으로 처리한다. 실패가 아니다.
- **INV-T3**: 구조 경계 테스트는 명령 문자열이나 도구 이름에서 권한 의미를 추론하지 않는다.
- **INV-T4**: 한 Gate 요청의 pending/HITL 상태는 다른 Keeper 또는 같은 Keeper의 독립 작업 lane을 중단시키지 않는다.
- **INV-T5**: `anti_fake` penalty 패턴에 매칭되는 테스트 파일은 `quality_tier`에서 경고 또는 위험으로 분류된다.
- **INV-T6**: Contract harness는 외부 서버에 의존하지 않는다. Hermetic bootstrap 경로만 사용한다.
- **INV-T7**: `eval_harness` 시나리오의 `max_cost_usd` 초과는 telemetry/warning only이다. Cost만으로 `trajectory_outcome`을 `CostExceeded`, `Gated`, `Failed`, 또는 `Timeout`으로 바꾸면 안 된다.

---

## 10. 테스트 작성 가이드

### 10.1 새 테스트 추가 시

1. `test/dune`에 테스트 등록 (pure sync면 최상단 `(tests ...)` 블록, Eio 의존이면 개별 `(test ...)` 블록)
2. Hermetic required로 분류 가능한지 확인. 외부 의존이 있으면 env-gated 계층에 배치.
3. `assert true` 사용 금지. `Alcotest.check` 또는 의미 있는 assertion 사용.
4. 외부 서비스 mock은 테스트 내부에서 처리. `test/dune`의 env 격리에 의존.

### 10.2 Keeper 행동 테스트 추가 시

1. `eval_harness.scenario` 정의 (goal, tool_expectations, graders)
2. 타입/경로/격리 같은 객관적 불변식은 deterministic assertion으로, 의미·품질 판단은 configured LLM grader로 검증.
3. `trajectory` 로깅으로 재현성 확보.
4. 외부 효과는 exact Always Allowed, configured LLM Auto Judge, nonblocking HITL의 Gate 계약을 검증.

---

## 11. References

| 문서 | 경로 |
|------|------|
| Verification matrix | `docs/VERIFICATION-MATRIX.md` |

# Verification Matrix

`masc`의 검증은 변경 단계와 실행 주체에 따라 나뉜다. 이 문서는 일반 PR 게이트, 릴리스 후보 검증, 환경 의존 검증, 수동 실험을 구분한다.

> **코딩 에이전트 규칙**: `docs/constitution.xml` `<execution_protocol>`에 따라 외부 코딩 에이전트 세션은 로컬 `dune build` / `dune test`를 실행하지 않는다. 아래 로컬 명령은 사람 기여자 또는 전용 툴체인이 있는 Keeper 레인 기준이다.

## 1. CI & Release Tiers

- **일반 PR 병합 게이트 (`merge-compile.yml`)**:
  - 스택 최상단 병합 대상 head에 대한 컴파일·타입 게이트(`merge-compile`)와 현재 head 독립 소스 리뷰를 확인한다.
- **릴리스 후보 검증 (`release-candidate.yml` + `config/release-behavior.json`)**:
  - 전체 컴파일/타입 검증, 4개 플랫폼 설치 검증, 그리고 `config/release-behavior.json`(`release-behavior.yml`)에 고정된 핵심 동작 테스트를 실행한다.
- **일일 및 수동 회귀 검증 (`test.yml`)**:
  - 루트 `@runtest` 전체 단위/통합 테스트 묶음은 일일 스케줄 및 `workflow_dispatch`에서 실행된다.

## 2. Hermetic Test Suites

외부 DB, live network, viewer/toolchain, local llama runtime 없이 재현 가능한 계층이다:

- `dune test --root .`
  - 기본 단위/통합 테스트 묶음 (`make test` 또는 `scripts/ci-run-tests.sh "opam exec -- dune test"`)
- `MASC_E2E_TESTS=true scripts/dune-local.sh build @test/runtest-test_sse_storm_e2e`
  - server executable 기반 SSE reconnect e2e
- transport harness suite
  - `scripts/harness/transport/run_all.sh`
  - self-bootstrapping local server + gRPC/WS/h2c smoke
- contract harness
  - `scripts/harness/contract/streamable_http_contract.sh`
  - `scripts/harness/contract/golden_path_1_contract.sh`

사람 기여자 로컬 진입점:

```bash
dune build --root .
make test
make test-transport
make test-contract
MASC_E2E_TESTS=true scripts/dune-local.sh build @test/runtest-test_sse_storm_e2e
```

의도:

- 기본 브랜치가 초록이면 core MCP/HTTP/keeper/operator 계약이 깨지지 않았다고 볼 수 있어야 한다.
- contract/transport harness는 서버가 이미 떠 있음을 전제로 하지 않고 hermetic bootstrap 경로로 실행돼야 한다.

## 3. Optional Env-Gated

특정 환경이 있을 때만 의미가 있는 계층이다. CI 기본 초록과 동일시하면 안 된다.

대표 항목:

- live network / realtime 환경 의존
  - live ICE/STUN/TURN/browser interop proof
  - 공용 CI에서는 hermetic signaling/data-plane smoke만 돌리고, 인터넷 상호운용성은 env-gated로 분리한다
- local viewer/toolchain 의존
  - `scripts/viewer-local-e2e-check.sh --build-viewer`

규칙:

- env가 없으면 skip 또는 not run으로 남길 수 있다.
- CI 로그/문서에는 왜 실행하지 않았는지가 드러나야 한다.
- 이 계층의 결과는 해당 env gate 안에서만 해석한다.

## 4. Manual Experiment

정합성 게이트가 아니라 오케스트레이션·벤치마크·동작 실험 계층이다. runbook과 함께 다룬다.

대표 항목:

- benchmark / keeper fleet proof
  - `scripts/harness/workload/agent_swarm_live.sh`
  - `docs/BENCHMARK-RUNBOOK.md`
- supervised delivery / operator path
  - `docs/SUPERVISOR-MODE.md`
- local runtime capacity
  - `scripts/llama-runtime-pool.sh`
  - `docs/PERFORMANCE-SLO.md`

규칙:

- pass/fail만 보지 않는다.
- proof artifact, report, runtime 전제, 모델 선택 근거를 함께 남긴다.
- 기본 CI 필수 게이트로 올리지 않는다.

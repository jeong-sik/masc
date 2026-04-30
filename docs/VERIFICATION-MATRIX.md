# Verification Matrix

`masc-mcp`의 검증은 한 덩어리가 아니다. 이 문서는 무엇이 기본 게이트이고, 무엇이 환경 의존 검증이며, 무엇이 수동 실험인지 구분하는 SSOT다.

## 1. Hermetic Required

이 계층은 외부 DB, live network, viewer/toolchain, local llama runtime 없이도 재현 가능해야 한다.

이 슬라이스에서 **CI-required**로 보는 항목:

- `dune test --root .`
  - 기본 단위/통합 테스트 묶음
  - 실행 진입점은 `make test` 또는 `scripts/ci-run-tests.sh "opam exec -- dune test"`를 기준으로 본다
- `./_build/default/test/test_sse_storm_e2e.exe`
  - server executable 기반 SSE reconnect e2e
- transport harness suite
  - `scripts/harness/transport/run_all.sh`
  - self-bootstrapping local server + gRPC/WS/WebRTC/h2c smoke
- contract harness 3종
  - `scripts/harness/contract/streamable_http_contract.sh`
  - `scripts/harness/contract/team_session_contract.sh`
  - `scripts/harness/contract/golden_path_1_contract.sh`

로컬 진입점:

```bash
dune build --root .
make test
make test-transport
make test-contract
./_build/default/test/test_sse_storm_e2e.exe
```

의도:

- 기본 브랜치가 초록이면 core MCP/HTTP/keeper/operator 계약이 깨지지 않았다고 볼 수 있어야 한다.
- contract/transport harness는 “서버가 이미 떠 있음”을 전제로 하지 않고 hermetic bootstrap 경로로 실행돼야 한다.
- `archive/trpg/scripts/` 아래의 game-view/TRPG 계약 스크립트는 active CI-required contract suite가 아니라 archive/manual 성격으로 본다.

## 2. Optional Env-Gated

이 계층은 특정 환경이 있을 때만 의미가 있다. CI 기본 초록과 동일시하면 안 된다.

대표 항목:

- live network / realtime 환경 의존
  - live ICE/STUN/TURN/browser interop proof
  - `scripts/harness/transport/verify_webrtc_live_env.sh`
  - `.github/workflows/webrtc-live-interop.yml`
  - 공용 CI에서는 hermetic signaling/data-plane smoke만 돌리고, 인터넷 상호운용성은 env-gated로 분리한다
- local viewer/toolchain 의존
  - `scripts/viewer-local-e2e-check.sh --build-viewer`

규칙:

- env가 없으면 skip 또는 not run으로 남길 수 있다.
- CI 로그/문서에는 “왜 안 돌았는지”가 드러나야 한다.
- 이 계층의 green은 bonus이고, red는 해당 env gate 안에서만 해석한다.

## 3. Manual Experiment

이 계층은 correctness gate가 아니라 orchestration/benchmark/behavior 실험이다. runbook과 함께 다뤄야 한다.

대표 항목:

- benchmark / swarm proof
  - `scripts/harness_agent_swarm_live.sh`
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

## Current Intent In This Slice

이번 슬라이스의 목적은 다음 두 가지다.

- `Hermetic Required`를 실제 기본 게이트로 올린다.
- transport discovery + gRPC/WS/WebRTC local smoke를 기본 게이트로 올린다.
- `Optional Env-Gated`와 `Manual Experiment`를 green으로 위장하지 않도록 분리해서 설명한다.

즉, 이번 변경에서 CI 필수로 보려는 것은:

- `make test`
- `make test-transport`
- `test_sse_storm_e2e.exe`
- contract harness 3종

그리고 이번 변경에서 **필수로 올리지 않는 것**은:

- PostgreSQL/live network/viewer/local llama runtime 의존 검증
- benchmark/swarm/team-session workload 실험

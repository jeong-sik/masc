---
status: runbook
last_verified: 2026-05-15
code_refs:
  - scripts/harness/workload/agent_swarm_live.sh
  - test/
---

# Benchmark Runbook

이 문서는 `single-agent baseline`과 keeper-fleet managed-operation proof lane을 같은 workload에 걸어 비교할 때 쓰는 운영 레시피다.

merged 기준 상위 진입점은 [INTEGRATED-BENCHMARK-RUNBOOK.md](./INTEGRATED-BENCHMARK-RUNBOOK.md)를 본다.

Command Plane search-fabric benchmark는 제거되었다. `best_first_v1` synthetic comparison을 새 runbook이나 harness에서 참조하지 않는다.

대상 workload 예:

- 코드 수정/검증/리뷰용 `coding_task`
- repo code + docs + tests를 함께 읽는 `repo_synthesis`
- 최신 AI 연구/공식 발표/리뷰 수집
- normalize / verify / curate / rank / audit 파이프라인

## 기준 원칙

- 기본 delivery path는 supervised execution + Supervisor이고, 이 문서의 managed-operation lane은 benchmark/compatibility용이다
- 기본 workload는 `coding_task`, `research_pipeline`은 explicit profile이다
- removed Command Plane search strategy harness는 benchmark 경로에 포함되지 않음
- removed `masc_swarm_*` public tools는 benchmark 경로에 포함되지 않음
- supervisor/session runtime은 별도 모드
- 사실 메타데이터 truth는 source metadata + rules
- MODEL은 summary/tagging/audit 보조만 담당

## Front-Door Latency Truth

빠른 성능 진단은 orchestration harness보다 먼저 MCP 세션 비용과 local runtime 비용을 분리해서 읽는다.

```bash
./benchmarks/quick-bench.sh
./benchmarks/benchmark.sh all 3
```

해석 규칙:

- 두 스크립트 모두 session-less `tools/call`을 재지 않는다.
- 항상 `initialize -> notifications/initialized -> Mcp-Session-Id 재사용` 순서를 포함한다.
- `mcp_session_init`은 세션 생성 비용이다.
- `mcp_read_*`, `mcp_workspace_*`, `mcp_lock`, `mcp_a2a_*`는 established session 위의 MCP path다.
- `oas_runtime_status`, `oas_runtime_single`은 raw local runtime lane이다.
- `local64`는 target runtime profile 이름이다. 실제 병렬 용량은 `masc_runtime_verify`의 `configured_capacity`, `healthy_runtime_count`를 기준으로 읽는다.

운영 팁:

- `quick-bench.sh`는 기본 smoke다. `BENCH_ITERATIONS=10 BENCH_WARMUP_ITERATIONS=1`처럼 첫 샘플을 제외하고 재면 분산이 덜 흔들린다.
- `benchmark.sh`는 결과를 `benchmarks/results/results_<timestamp>.csv`에 누적 저장한다.
- 같은 디렉터리에 `results_<timestamp>.meta.json`, `results_<timestamp>.diff.txt`를 남기고, 기본값으로 직전 CSV와 비교한다.
- baseline 자동 비교를 끄려면 `BENCH_COMPARE_TO=none`, 특정 baseline을 강제하려면 `BENCH_COMPARE_TO=/abs/path/to/results.csv`를 쓴다.

## 실험 구조

### Baseline

- 한 에이전트가 fetch 이후 normalize/verify/curate/rank/audit를 순차 실행

### Keeper Fleet

- company
  - benchmark 전체 총괄
- platoon
  - lane 단위: `research`, `official`, `reviews`
- squad
  - stage 단위: `normalize`, `verify`, `curate`, `rank`, `audit`
- agent
  - 실제 worker

## Repo Synthesis Phase 1

Phase 1 corpus는 `masc` 단일 repo다.

- front door:
  - none; benchmark inputs are read from command-plane truth surfaces and artifacts
- fairness:
  - same model
  - same time budget
  - same tool budget
- score axes:
  - `evidence_precision`
  - `claim_coverage`
  - `unsupported_claim_penalty`
  - `latency_ms`
- deterministic harness:

```bash
./scripts/harness_repo_synthesis_benchmark.sh
```

question set은 `benchmarks/data/repo_synthesis_question_set.json`에 있고,
baseline/fleet fixture answers는 `test/fixtures/repo_synthesis_benchmark/`에 있다.

## 준비 순서

1. Namespace / Task hygiene 완료
   - `masc_start`
   - `masc_transition(action="claim")` 또는 `masc_claim_next`
   - 필요 시 `masc_plan_set_task`
   - `masc_heartbeat`
2. benchmark 준비
   - keeper fleet readiness 확인

## 첫 smoke는 18+ keeper fleet evidence로 한다

`team-session`/public `swarm` read surface와 old entrypoint는 retired 되었다.
Canonical gate는 read-only keeper fleet readiness만 실행한다.

```bash
scripts/harness/workload/agent_swarm_live.sh
```

기본 전제:

- `EXPECTED_KEEPERS=18`
- latest terminal turns sampled per keeper = 3
- keeper별 terminal turns >= 3
- keeper별 successful provider turns >= 3
- receipt/checkpoint/provider-closure/memory/tool-log coverage = 100%

이 harness는:

- 18명 이상 keeper의 runtime manifest evidence가 있는지 확인한다
- 각 keeper가 provider-dispatched successful turn을 충분히 남겼는지 확인한다
- `.masc/keepers/<keeper>/runtime-manifests`, execution receipts,
  checkpoints, memory-bank rows, tool-call log links가 서로 이어지는지
  확인한다
- 결과를 `logs/keeper_fleet_readiness/<run-id>/summary.json`에 남긴다

주의:

- 이 경로는 read-only proof다. keepers를 시작하거나 LLM 호출을 새로 만들지 않는다.
- live mutation/probe가 필요하면 keeper lifecycle reprobe harness를 별도로 실행한
  뒤 이 gate로 runtime truth를 닫는다.
- 누락 데이터는 fail이다. "not run" 또는 stale evidence를 green으로 취급하지 않는다.

## session runtime local64 compat lane

Removed. Team-session compat harnesses and the command-plane HTTP lane are both retired; use board_posts + keeper FSM read models for workspace collaboration truth and the canonical dashboard projections (`/api/v1/dashboard/briefing`, `/api/v1/dashboard/execution`, `/api/v1/dashboard/board`) for live proof.

Operation/unit/detachment tool variants were removed (no implementation existed).

## detachment materialization

Operation/unit/detachment tool variants were removed (no implementation existed).
Benchmark workflows use live tools only.

## approval / rebalance

cross-platoon rebalance나 strict action은 바로 적용되지 않을 수 있다.
```

그 다음 순서:

1. `masc_operator_snapshot` 후 `masc_operator_confirm`

## 체크포인트와 종료

Operation/unit/detachment tools were removed. Checkpoint/finalize workflows use live tools.

## 무엇을 비교하나

- end-to-end latency
- stage latency
- provenance coverage
- stale detection rate
- quarantine precision/recall
- alert frequency
- approval queue frequency
- recovery time after injected failure

## 대시보드에서 반드시 봐야 하는 것

- `Operations`
  - active op 수
  - detachment materialization 여부
- `Topology`
  - company/platoon/squad tree
  - leader / roster / utilization
- `Alerts`
  - stalled detachment
  - quiet leader
  - over-capacity unit
- `Trace`
  - checkpoint
  - dispatch
  - policy
  - failover
- `Control`
  - pending approval
  - freeze / kill-switch

## Removed Search Fabric V1

The old Command Plane search-fabric synthetic benchmark was removed with the CP purge. Do not restore the deleted search-fabric doc, wrapper scripts, or `test_cp_search_fabric_benchmark` target without a new current RFC and runnable test target.

## Integrated Entry Point

merged 아키텍처 전체를 한 번에 읽고 싶으면 wrapper를 쓴다.

```bash
./scripts/harness_integrated_benchmark.sh
```

빠른 smoke:

```bash
INTEGRATED_BENCH_PHASES=control ./scripts/harness_integrated_benchmark.sh
```

full substrate:

```bash
INTEGRATED_BENCH_PHASES=control \
LLAMA_SWARM_MODEL=<exact-model-id> \
./scripts/harness_integrated_benchmark.sh
```

## 실패 패턴

- task를 claim했는데 logs가 current task를 못 찾음
  - `masc_plan_set_task`
- agent가 사라진 것처럼 보임
  - `masc_heartbeat`

## 관련 문서

- [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)

## OAS Descriptor Dispatch (Phase B baseline)

`~/me/planning/claude-plans/wise-nibbling-lerdorf.md` Phase B 의 evidence
수집 절차. 두 hot path (`make_tool_bundle` @ `lib/keeper/keeper_tools_oas.ml:852`,
`params_of_json_schema` @ `lib/tool_bridge.ml:176`) 가 keeper turn 예산에서
차지하는 비중을 측정해 Phase C 진행 여부를 결정한다.

### Histograms

- `masc_oas_params_of_schema_sec` — sum/count, 매 OAS conversion 마다
  observation 1 회.
- `masc_oas_make_tool_bundle_sec` — sum/count, 매 keeper turn 1 회.

masc 의 hot-path metric surface 는 sum + `_count` 만 저장하므로
*평균(avg = sum/count)* 까지가 in-tree 측정 한계다. p50/p95/p99 quantile 이
필요하면 외부 time-series backend 또는 별도 raw-sample 경로가 필요하다
(현재 Phase B 범위 밖).

### Smoke run

```bash
# 1. 워크로드 구동 (운영자 재량). 기본 권장: tool-call-quality --live.
BENCH_ITERATIONS=50 BENCH_WARMUP_ITERATIONS=1 \
  ./scripts/harness_tool_call_quality.sh --live --keepers bench-analyst \
    --models <provider:model>

# 2. configured OTel backend에서 아래 series의 sum/count를 query한다.
#    - masc_oas_params_of_schema_sec
#    - masc_oas_params_of_schema_sec_count
#    - masc_oas_make_tool_bundle_sec
#    - masc_oas_make_tool_bundle_sec_count
#
# 3. 비교는 backend query 결과의 avg = sum/count 기준으로 수행한다.
```

### Histogram-overhead control

`MASC_DISABLE_HOTPATH_HIST=1` 로 서버를 기동하면 두 hot path 의 observation 이
no-op 으로 빠진다. 동일 워크로드를 hist-on / hist-off 로 두 번 돌려 차이가
없으면 histogram 자체 비용이 무시 가능 (Phase B 결과의 신뢰도 확인용).

### Decision gate (Phase B → Phase C)

```
(avg make_tool_bundle + avg params_of_json_schema × tools_per_turn) / avg total_turn >= 0.02
```

위 식이 참이면 Phase C (`params_of_json_schema` memoization) 진행. 거짓이면
Phase C/D 미진행 — evidence finding 만 follow-up 으로 남기고 plan 종료.

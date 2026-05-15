---
status: runbook
last_verified: 2026-05-15
code_refs:
  - scripts/harness_keeper_campaign.sh
  - scripts/harness_agent_swarm_live.sh
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
- `mcp_read_*`, `mcp_coord_*`, `mcp_lock`, `mcp_a2a_*`는 established session 위의 MCP path다.
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

Phase 1 corpus는 `masc-mcp` 단일 repo다.

- front door:
  - `masc_autoresearch_cycle` (repo-synthesis is dispatched internally via the cycle system)
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

question set은 `benchmark/repo_synthesis_question_set.json`에 있고,
baseline/fleet fixture answers는 `test/fixtures/repo_synthesis_benchmark/`에 있다.

## 준비 순서

1. Namespace / Task hygiene 완료
   - `masc_start`
   - `masc_transition(action="claim")` 또는 `masc_claim_next`
   - 필요 시 `masc_plan_set_task`
   - `masc_heartbeat`
2. unit hierarchy 생성
   - `masc_unit_define`
3. benchmark operation 시작
   - `masc_operation_start`
4. scheduler reconcile
   - `masc_dispatch_tick`

## 첫 smoke는 18+ keeper fleet evidence로 한다

`team-session`/public `swarm` read surface는 retired 되었다. Compatibility
entrypoint 이름은 유지하지만, `scripts/harness_agent_swarm_live.sh`는 이제
read-only keeper fleet readiness gate를 실행한다.

```bash
scripts/harness_agent_swarm_live.sh
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
  checkpoints, memory injection rows, tool-call log links가 서로 이어지는지
  확인한다
- 결과를 `logs/keeper_fleet_readiness/<run-id>/summary.json`에 남긴다

주의:

- 이 경로는 read-only proof다. keepers를 시작하거나 LLM 호출을 새로 만들지 않는다.
- live mutation/probe가 필요하면 keeper lifecycle reprobe harness를 별도로 실행한
  뒤 이 gate로 runtime truth를 닫는다.
- 누락 데이터는 fail이다. "not run" 또는 stale evidence를 green으로 취급하지 않는다.

## session runtime local64 compat lane

Removed. Team-session compat harnesses and the command-plane HTTP lane are both retired; use board_posts + keeper FSM read models for coordination truth and the canonical dashboard projections (`/api/v1/dashboard/mission`, `/api/v1/dashboard/execution`, `/api/v1/dashboard/board`) for live proof.

## 최소 unit 예시

```json
{
  "tool": "masc_unit_define",
  "arguments": {
    "unit_id": "company-radar",
    "kind": "company",
    "label": "AI Research Radar Company",
    "leader_id": "codex"
  }
}
```

```json
{
  "tool": "masc_unit_define",
  "arguments": {
    "unit_id": "platoon-research",
    "kind": "platoon",
    "label": "Research Platoon",
    "parent_unit_id": "company-radar",
    "leader_id": "codex",
    "policy": {
      "autonomy_level": "L4_Autonomous"
    }
  }
}
```

```json
{
  "tool": "masc_unit_define",
  "arguments": {
    "unit_id": "squad-verify",
    "kind": "squad",
    "label": "Verify Squad",
    "parent_unit_id": "platoon-research",
    "leader_id": "local-worker-1",
    "roster": ["local-worker-1", "local-worker-2"]
  }
}
```

## operation 예시

```json
{
  "method": "POST",
  "path": "/api/v1/command-plane/operations",
  "headers": {
    "x-masc-agent-name": "codex"
  },
  "body": {
    "assigned_unit_id": "squad-verify",
    "objective": "Verify and quarantine new research items",
    "autonomy_level": "L4_Autonomous",
    "policy_class": "guarded",
    "budget_class": "standard"
  }
}
```

예상 확인 포인트:

- `masc_observe_operations`에 operation이 보임
- `trace_id`가 발급됨
- actor header를 생략하면 operation `created_by`가 `dashboard`로 떨어질 수 있음

## detachment materialization

```json
{
  "tool": "masc_dispatch_tick",
  "arguments": {
    "operation_id": "op-..."
  }
}
```

바로 이어서:

- `masc_detachment_list`
- `masc_detachment_status`
- `masc_observe_alerts`
- `masc_observe_traces`

## approval / rebalance

cross-platoon rebalance나 strict action은 바로 적용되지 않을 수 있다.

```json
{
  "tool": "masc_dispatch_rebalance",
  "arguments": {
    "operation_id": "op-...",
    "target_unit_id": "squad-verify-alt"
  }
}
```

이때 가능한 응답:

```json
{
  "status": "pending_approval",
  "decision_id": "decision-..."
}
```

그 다음 순서:

1. `masc_policy_status`
2. `masc_policy_approve` 또는 `masc_policy_deny`
3. `masc_dispatch_tick`

## 체크포인트와 종료

```json
{
  "tool": "masc_operation_checkpoint",
  "arguments": {
    "operation_id": "op-...",
    "checkpoint_ref": "bench-run-2026-03-07T13:00Z",
    "note": "normalized 48 items, 3 quarantined"
  }
}
```

```json
{
  "tool": "masc_operation_finalize",
  "arguments": {
    "operation_id": "op-...",
    "note": "benchmark run completed"
  }
}
```

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

- operation만 있고 detachment가 없음
  - `masc_dispatch_tick`
- detachment heartbeat_deadline이 만료됨
  - `masc_dispatch_tick`
  - 필요 시 `masc_policy_status`
- task를 claim했는데 logs가 current task를 못 찾음
  - `masc_plan_set_task`
- agent가 사라진 것처럼 보임
  - `masc_heartbeat`

## 관련 문서

- [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)

## Eval Pipeline (Quality Scoring)

Keeper의 tool call 품질을 정량 평가하는 파이프라인. 현재는 두 가지 평가 경로가 `Reward_advice_artifact.reward_advice_artifact`로 수렴하며, `Task verifier` 경로는 future로 계획되어 있다.

### 구조

```
Post_verifier     →  of_post_verifier_verdict  →  reward_advice_artifact
  (turn 출력 검사)       (content quality)

Benchmark         →  of_benchmark_case_score    →  reward_advice_artifact
  (tool call 정밀도)     (composite_score → multiplier band)

Task verifier     →  (future)                   →  reward_advice_artifact
```

### Verdict → Multiplier 매핑

| Verdict | Multiplier | 설명 |
|---------|-----------|------|
| `Pass` | 1.0 (post_verifier), 1.1 (benchmark) | 정상 동작 |
| `Warn` | 0.8 (post_verifier), 0.9 (benchmark) | 품질 저하 |
| `Fail` | 0.4 (post_verifier), 0.5 (benchmark) | 심각한 문제 |

### 코드 위치

| 모듈 | 역할 |
|------|------|
| `reward_advice_artifact.ml` | 평가 결과 record, JSON serialization, verdict→multiplier |
| `post_verifier.ml` | keeper turn 출력 품질 검사 (공백/의미없는 응답 탐지) |
| `tool_call_quality_benchmark.ml` | tool call 정밀도 벤치마크 (case_score → reward_advice) |
| `tool_call_quality_benchmark_types.ml` | case_score, benchmark_case 등 타입 정의 |
| `tool_call_quality_benchmark_scoring.ml` | composite_score 산출 |
| `tool_call_quality_benchmark_loader.ml` | 벤치마크 case/evidence 파일 로딩 |
| `tool_call_quality_benchmark_render.ml` | 벤치마크 결과 렌더링 |

### 테스트

```bash
dune runtest test/test_reward_advice_artifact.ml
dune runtest test/test_post_verifier.ml
dune runtest test/test_tool_call_quality_benchmark.ml
```

## OAS Descriptor Dispatch (Phase B baseline)

`~/me/planning/claude-plans/wise-nibbling-lerdorf.md` Phase B 의 evidence
수집 절차. 두 hot path (`make_tool_bundle` @ `lib/keeper/keeper_tools_oas.ml:852`,
`params_of_json_schema` @ `lib/tool_bridge.ml:176`) 가 keeper turn 예산에서
차지하는 비중을 측정해 Phase C 진행 여부를 결정한다.

### Histograms

- `masc_oas_params_of_schema_sec` — sum/count, 매 OAS conversion 마다
  observation 1 회.
- `masc_oas_make_tool_bundle_sec` — sum/count, 매 keeper turn 1 회.

masc-mcp 의 `Prometheus.observe_histogram` 은 sum + `_count` 만 저장하므로
*평균(avg = sum/count)* 까지가 in-tree 측정 한계다. p50/p95/p99 quantile 이
필요하면 외부 Prometheus scraper + `histogram_quantile()` 또는 별도 raw-sample
경로가 필요하다 (현재 Phase B 범위 밖).

### Smoke run

```bash
# 1. 워크로드 구동 (운영자 재량). 기본 권장: tool-call-quality --live.
BENCH_ITERATIONS=50 BENCH_WARMUP_ITERATIONS=1 \
  ./scripts/harness_tool_call_quality.sh --live --keepers bench-analyst \
    --models <provider:model>

# 2. /metrics 스크레이프 + CSV 저장.
./scripts/harness_oas_dispatch.sh scrape --label baseline

# 3. 비교 (e.g. memoization 적용 전후, 또는 hist on/off).
./scripts/harness_oas_dispatch.sh diff \
  benchmarks/results/oas-baseline-<base>.csv \
  benchmarks/results/oas-baseline-<current>.csv
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

# Benchmark Runbook

이 문서는 `single-agent baseline`과 managed-operation swarm lane을 같은 workload에 걸어 비교할 때 쓰는 운영 레시피다.

merged 기준 상위 진입점은 [INTEGRATED-BENCHMARK-RUNBOOK.md](./INTEGRATED-BENCHMARK-RUNBOOK.md)를 본다.

Search-aware routing 실험은 [SEARCH-FABRIC-V1.md](./SEARCH-FABRIC-V1.md)를 같이 본다.

대상 workload 예:

- 코드 수정/검증/리뷰용 `coding_task`
- repo code + docs + tests를 함께 읽는 `repo_synthesis`
- 최신 AI 연구/공식 발표/리뷰 수집
- normalize / verify / curate / rank / audit 파이프라인

## 기준 원칙

- 기본 delivery path는 Team Session + Supervisor이고, 이 문서의 managed-operation lane은 benchmark/compatibility용이다
- 기본 workload는 `coding_task`, `research_pipeline`은 explicit profile이다
- 기본 routing은 `best_first_v1`, `legacy`는 explicit opt-out이다
- removed `masc_swarm_*` public tools는 benchmark 경로에 포함되지 않음
- supervisor/team-session은 별도 모드
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

### Swarm

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
  - `masc_repo_synthesis_swarm_start`
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
baseline/swarm fixture answers는 `test/fixtures/repo_synthesis_benchmark/`에 있다.

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

## 첫 smoke는 12-worker live harness로 한다

실제 외부 소스를 긁기 전에 deterministic fixture로 orchestration부터 증명한다.

```bash
LLAMA_PRESET=qwen35-hot ~/me/scripts/llama-server.sh restart
scripts/harness_agent_swarm_live.sh
```

전제:

- `qwen35-hot`는 `ctx=262144`를 유지한다.
- `hot-swarm` track은 ctx 축소 fallback을 허용하지 않는다.
- `provider smoke + slot contract + live harness`가 모두 지나야 성공으로 본다.

이 harness는:

- worker 12명 이상이 실제로 join/claim/current_task/heartbeat/done/final marker를 남기는지 확인한다
- managed-operation swarm read model과 dashboard가 그 사실을 올바르게 표현하는지 함께 검증한다
- 외부 네트워크 fetch 없이 synthetic fixture만 사용한다

기대 체크리스트:

- peak hot slots >= 10
- detachment materialized
- joined workers = expected workers
- current task bound = expected workers
- fresh heartbeats = expected workers
- completed workers = expected workers
- final markers seen = expected workers
- provider reachable = true
- actual slots >= expected slots
- actual ctx = expected ctx = 262144

주의:

- `masc_transition(action="claim")`만으로는 planning `current_task`가 안 잡힌다. 이 경로를 쓰면 각 worker는 `masc_plan_set_task`를 호출해야 한다.
- `masc_claim_next`는 current builds에서 planning `current_task`를 auto-bind 한다.
- `masc_dispatch_tick`을 안 돌리면 detachment가 생기지 않는다.
- `hot 10+`는 orchestration proof와 별개다. `llama.cpp /slots` 샘플이 없으면 pass로 보지 않는다.
- worker가 완료 후 leave해도 completed task ownership과 final marker가 있으면 swarm read model은 복원 가능해야 한다.
- 실패 시 `provider_unreachable`, `provider_model_mismatch`, `slot_count_insufficient`, `ctx_mismatch` 같은 runtime blocker를 artifact와 dashboard에서 바로 읽을 수 있어야 한다.

## team-session local64 compat lane

hot-swarm proof와 별도로, `./scripts/harness_team_session_local64_smoke.sh`는 `team_session_swarm_runner.ml` 기반의 team-session/OAS bridge를 검증하는 보조 lane이다.

이 경로는 다음을 검증할 때 쓴다.

- `masc_team_session_start` + `masc_team_session_step(spawn_batch=...)` 흐름이 실제 local worker spawn으로 이어지는지
- `team_session_oas_bridge.ml`가 session state를 swarm config로 정확히 투영하는지
- `team_session_swarm_runner.ml` / `team_session_swarm_callbacks.ml`가 turn, event, proof artifact를 남기는지
- explicit model 선택과 local64 runtime attach가 session proof에서 보이는지

이 모드는 보조 경로다.

- managed-operation live proof의 pass/fail 기준을 대체하지 않는다
- managed-operation operation/detachment/current_task truth는 여전히 live harness/read model 쪽이다
- task claim/current_task semantics 자체를 검증하려면 `./scripts/harness_agent_swarm_live.sh`를 사용한다

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

## Search Fabric V1

`best_first_v1`는 기존 managed-operation 표면 위에 붙는 opt-in strategy다.

- `masc_operation_start`에 `workload_profile="research_pipeline"`와 `search_strategy="best_first_v1"`를 넘긴다.
- downstream stage는 `depends_on_operation_ids`로 연결한다.
- benchmark comparison은 `./scripts/harness_cp_search_fabric.sh`로 synthetic workload를 두 전략(`legacy`, `best_first_v1`)에 각각 실행한다.

## Integrated Entry Point

merged 아키텍처 전체를 한 번에 읽고 싶으면 wrapper를 쓴다.

```bash
./scripts/harness_integrated_benchmark.sh
```

빠른 smoke:

```bash
INTEGRATED_BENCH_PHASES=search ./scripts/harness_integrated_benchmark.sh
```

full substrate:

```bash
INTEGRATED_BENCH_PHASES=control,search,local64 \
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

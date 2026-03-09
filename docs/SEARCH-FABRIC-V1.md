# Search Fabric V1

`Search Fabric V1`는 `masc-mcp` swarm을 새 public swarm API로 다시 만들지 않고,
기존 `CPv2` 위에 `micro-op pipeline + programmable search brain`을 얹는 실험이다.

## Scope

- 대상 workload: `research_pipeline`
- 대상 stage: `normalize -> verify -> curate -> rank -> audit`
- public 표면: 기존 `masc_operation_start`, `masc_dispatch_plan`, `masc_dispatch_tick`, `masc_observe_operations`
- 기본 동작: `legacy`
- opt-in 전략: `best_first_v1`

## Mapping

- `operation` = micro-op
- `detachment` = reservation station
- `unit` = execution resource
- `checkpoint_ref` = commit token
- `dispatch_tick` = issue + repair cycle

`best_first_v1`는 dependency-ready operation만 issue한다.
업스트림 operation이 `Completed`이거나 `checkpoint_ref`를 가진 경우에만 downstream이 ready가 된다.

## Routing Rules

- `best_first_v1`는 approval이 필요 없는 candidate만 본다.
- score는 고정이다:
  - `capability_match 0-40`
  - `capacity_headroom 0-20`
  - `posterior_success 0-20`
  - `queue_age 0-10`
  - `stickiness 10`
- reassignment는 새 candidate가 현재 unit보다 `15점 이상` 높을 때만 일어난다.
- prior는 `(unit_id, stage)` 단위로 `.masc/control-plane/search-stats.json`에 저장한다.
  - `checkpoint/finalize => alpha + 1`
  - `stall/escalate => beta + 1`

## Interface Additions

`masc_operation_start` optional fields:

- `workload_profile`
- `stage`
- `depends_on_operation_ids`
- `search_strategy`

`masc_dispatch_plan` output additions:

- `score`
- `score_breakdown`
- `routing_reason`
- `dependency_blockers`

`masc_observe_operations` / `masc_detachment_status` output additions:

- `search.strategy`
- `search.selected_unit_id`
- `search.candidates`
- `search.dependency_blockers`

Operator-facing 요약은 `masc_operator_digest`와 dashboard `Ops`에서 번역된 signal로 본다.
기본 surface는 `routing confidence`, `issue pressure`, `scheduler efficiency`, `cache contention` 같은 운영 의미를 사용하고,
`RISC/MESI/MCTS` raw 용어는 detail/diagnostic에서만 본다.

## Benchmark

Synthetic comparison executable:

```bash
dune exec ./test/test_cp_search_fabric_benchmark.exe
```

Wrapper script:

```bash
./scripts/harness_cp_search_fabric.sh
```

비교 포인트:

- `initial_detachments`
- `verify_blocked_before_checkpoint`
- `verify_final_detachments`
- `verify_assigned_unit`
- `elapsed_ms`

## Research Anchors

- [근거] Dependency-aware issue/commit model: [Tomasulo 1967](https://spacefrontiers.org/r/10.1147/rd.111.0008), [MIT Tagged-Token Dataflow](https://www.csail.mit.edu/research/architecture) + 확인일시 2026-03-08 + 신뢰도 High
- [근거] Spatial execution intuition: [Eyeriss](https://eyeriss.mit.edu/) + 확인일시 2026-03-08 + 신뢰도 High
- [근거] Search brain separation: [Tree of Thoughts](https://openreview.net/forum?id=5Xc1ecxO1h), [LATS](https://proceedings.mlr.press/v235/zhou24r.html), [AI Search Planner](https://arxiv.org/abs/2508.20368) + 확인일시 2026-03-08 + 신뢰도 High
- [근거] Non-pyramidal coordination: [Blackboard architecture](https://www.sciencedirect.com/science/article/pii/S0004370283800633), [Holonic architecture](https://link.springer.com/article/10.1007/s00170-024-14039-8) + 확인일시 2026-03-08 + 신뢰도 High/Medium

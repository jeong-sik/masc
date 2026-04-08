# Integrated Benchmark Runbook

이 문서는 merged 기준 `masc-mcp`를 한 번에 검증할 때 쓰는 상위 runbook이다.

아키텍처 맵은 [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)를 먼저 본다.

핵심 원칙:

- 새 benchmark substrate를 추가하지 않는다.
- 이미 mainline에 들어간 harness를 순차 실행해서 layer별 regression만 분리해 읽는다.
- default delivery path는 Team Session + Supervisor이고, 이 문서의 control lane은 managed-operation benchmark proof다
- scheduling policy는 `Search Fabric V1`
- implementation/runtime substrate는 `Team Session + local64`

## Layer Map

- `control`
  - direct swarm read model / detachment / heartbeat proof
  - harness: `./scripts/harness_agent_swarm_live.sh`
- `search`
  - `legacy` vs `best_first_v1` synthetic comparison
  - harness: `./scripts/harness_cp_search_fabric.sh`
- `local64`
  - same-box shard-pool session / runtime census / operator visibility
  - harness: `./scripts/harness_team_session_local64_smoke.sh`
  - `local64`는 target runtime profile 이름이다. 실제 capacity는 `masc_runtime_verify`로 확인한다.

## One-Shot Entrypoint

통합 entrypoint:

```bash
./scripts/harness_integrated_benchmark.sh
```

기본 phase:

- `control`
- `search`

`local64`는 model/runtime 준비가 되어 있을 때만 켠다:

```bash
INTEGRATED_BENCH_ENABLE_LOCAL64=true \
LLAMA_SWARM_MODEL=<exact-model-id> \
./scripts/harness_integrated_benchmark.sh
```

phase를 직접 고를 수도 있다:

```bash
INTEGRATED_BENCH_PHASES=search ./scripts/harness_integrated_benchmark.sh
INTEGRATED_BENCH_PHASES=control,search ./scripts/harness_integrated_benchmark.sh
INTEGRATED_BENCH_PHASES=control,search,local64 ./scripts/harness_integrated_benchmark.sh
```

## Dry Run

실행 전에 어떤 harness를 부를지 확인만 하고 싶으면:

```bash
INTEGRATED_BENCH_DRY_RUN=true \
INTEGRATED_BENCH_PHASES=control,search,local64 \
./scripts/harness_integrated_benchmark.sh
```

## Output Contract

wrapper는 phase별 log와 summary JSON을 남긴다.

- `summary.json`
  - phase 목록
  - 각 phase의 exit code
  - phase log 경로
  - `search` 결과 JSON
  - `local64` session id
- `01-control.log`
- `02-search.log`
- `03-local64.log`

마지막 줄은 항상 `summary=/abs/path/to/summary.json` 형식이다.

## Reading Failures

- `control` fail
  - managed-operation swarm live proof가 깨진 상태다.
  - detachment materialization, heartbeat, current task binding, final marker를 먼저 본다.
- `search` fail
  - `best_first_v1` policy layer regression 가능성이 높다.
  - `depends_on_operation_ids`, readiness gating, assigned unit, detachment delta를 먼저 본다.
- `local64` fail
  - runtime substrate 또는 session visibility 문제일 가능성이 높다.
  - `masc_runtime_verify`, `masc_team_session_status`, `masc_operator_digest`를 먼저 본다.

빠른 전후 비교가 필요하면 integrated harness 전에 다음을 먼저 돌린다:

```bash
BENCH_WARMUP_ITERATIONS=1 bash ./benchmarks/benchmark.sh all 5
```

이 스크립트는 직전 CSV와의 diff report를 같이 남긴다.

## Recommended Progression

1. `search`
   - synthetic policy regression 확인
2. `control,search`
   - managed-operation proof lane + policy layer 확인
3. `control,search,local64`
   - merged substrate 전체 확인
4. 필요 시 model ceiling 확인
   - `./scripts/harness_local64_model_matrix.sh`

## Related Docs

- [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)
- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- [SEARCH-FABRIC-V1.md](./SEARCH-FABRIC-V1.md)
- [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)

# Integrated Benchmark Runbook

이 문서는 merged 기준 `masc-mcp`를 한 번에 검증할 때 쓰는 상위 runbook이다.

아키텍처 맵은 [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)를 먼저 본다.

핵심 원칙:

- 새 benchmark substrate를 추가하지 않는다.
- 이미 mainline에 들어간 harness를 순차 실행해서 layer별 regression만 분리해 읽는다.
- default control lane은 managed-operation benchmark proof다.
- removed `swarm` / `team session` lanes는 이 runbook에 포함하지 않는다.

## Layer Map

- `control`
  - direct read model / detachment / heartbeat proof
  - harness: `./scripts/harness_agent_swarm_live.sh`
- `search`
  - `legacy` vs `best_first_v1` synthetic comparison
  - harness: `./scripts/harness_cp_search_fabric.sh`

## One-Shot Entrypoint

```bash
./scripts/harness_integrated_benchmark.sh
```

기본 phase:

- `control`
- `search`

phase를 직접 고를 수도 있다:

```bash
INTEGRATED_BENCH_PHASES=search ./scripts/harness_integrated_benchmark.sh
INTEGRATED_BENCH_PHASES=control,search ./scripts/harness_integrated_benchmark.sh
```

## Dry Run

```bash
INTEGRATED_BENCH_DRY_RUN=true \
INTEGRATED_BENCH_PHASES=control,search \
./scripts/harness_integrated_benchmark.sh
```

## Reading Failures

- `control` fail
  - managed-operation proof lane가 깨진 상태다.
  - detachment materialization, heartbeat, current task binding, final marker를 먼저 본다.
- `search` fail
  - `best_first_v1` policy layer regression 가능성이 높다.
  - `depends_on_operation_ids`, readiness gating, assigned unit, detachment delta를 먼저 본다.

## Related Docs

- [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)
- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- [SEARCH-FABRIC-V1.md](./SEARCH-FABRIC-V1.md)

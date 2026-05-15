# Integrated Benchmark Runbook

이 문서는 merged 기준 `masc-mcp`를 한 번에 검증할 때 쓰는 상위 runbook이다.

핵심 원칙:

- 새 benchmark substrate를 추가하지 않는다.
- 이미 mainline에 들어간 harness를 순차 실행해서 layer별 regression만 분리해 읽는다.
- default control lane은 keeper fleet benchmark proof다.
- removed `swarm` / `team session` lanes는 이 runbook에 포함하지 않는다.
- removed Command Plane search-fabric lane은 이 runbook에 포함하지 않는다.

## Layer Map

- `control`
  - 18+ keeper runtime evidence proof
  - harness: `./scripts/harness_agent_swarm_live.sh`
## One-Shot Entrypoint

```bash
./scripts/harness_integrated_benchmark.sh
```

기본 phase:

- `control`
- `search`

phase를 직접 고를 수도 있다:

```bash
INTEGRATED_BENCH_PHASES=control ./scripts/harness_integrated_benchmark.sh
```

## Dry Run

```bash
INTEGRATED_BENCH_DRY_RUN=true \
INTEGRATED_BENCH_PHASES=control \
./scripts/harness_integrated_benchmark.sh
```

## Reading Failures

- `control` fail
  - keeper fleet runtime evidence가 부족한 상태다.
  - observed keeper count, per-keeper successful provider turns, receipt/checkpoint
    links, memory injection rows, tool-call log links를 먼저 본다.
## Related Docs

- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)

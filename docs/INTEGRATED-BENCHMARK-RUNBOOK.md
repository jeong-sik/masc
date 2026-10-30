# Integrated Benchmark Runbook

`scripts/harness_integrated_benchmark.sh` is the current one-shot wrapper for
Keeper fleet runtime evidence.

## Run

```bash
./scripts/harness_integrated_benchmark.sh
```

The wrapper currently accepts one phase, `control`, backed by
`scripts/harness/workload/agent_swarm_live.sh`.

To inspect the planned command and output paths without starting the workload:

```bash
INTEGRATED_BENCH_DRY_RUN=true \
INTEGRATED_BENCH_PHASES=control \
./scripts/harness_integrated_benchmark.sh
```

The generated `summary.json` records the phase, script, log path, status, exit
code, timestamps, and aggregate result. A failed phase makes the wrapper exit
non-zero.

## Failure Reading

For a failed `control` phase, inspect its log for observed Keeper count,
successful provider turns, receipt/checkpoint links, and tool-call evidence.

For tool-selection and recovery quality, run
`scripts/harness_tool_call_quality.sh` separately.

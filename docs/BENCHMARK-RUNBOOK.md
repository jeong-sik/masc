# Benchmark Runbook

Use the benchmark whose evidence matches the question being asked.

## Keeper Fleet Runtime Evidence

```bash
./scripts/harness_integrated_benchmark.sh
```

This runs the `control` phase and writes a machine-readable `summary.json` plus
the phase log. See [INTEGRATED-BENCHMARK-RUNBOOK.md](./INTEGRATED-BENCHMARK-RUNBOOK.md).

## Tool-Calling Quality

Aggregate the checked-in evidence fixture:

```bash
./scripts/harness_tool_call_quality.sh
```

Run fresh isolated Keeper cases:

```bash
./scripts/harness_tool_call_quality.sh --live
```

The case catalog is `benchmarks/data/tool_call_quality_cases.json`. The live
mode starts an isolated local server, executes the cases, writes raw evidence,
and passes it through the benchmark CLI.

## Evidence Boundary

- Wrapper success proves only the named benchmark phase and emitted evidence.
- Local benchmark output is not exact-head CI proof.
- Deployment proof requires a separately identified running binary and commit.

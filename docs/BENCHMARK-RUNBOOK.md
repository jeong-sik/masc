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

## Isolated Server Ports

An isolated benchmark or campaign server must not bind the production ports
8935 (HTTP), 8936 (gRPC), or 8937 (WebSocket). Pick a port at 9400 or above,
the way the harness smoke runners already do. A campaign that binds 8937
blocks the production server from restarting: on 2026-08-29 an E0 campaign
server holding `--port=8937` had to be killed to bring the workspace back.

## Evidence Boundary

- Wrapper success proves only the named benchmark phase and emitted evidence.
- Local benchmark output is not exact-head CI proof.
- Deployment proof requires a separately identified running binary and commit.

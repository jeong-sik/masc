# Prepared execution response observation benchmark

This microbenchmark rereads real Candle/config/Board authority on every iteration
using a controlled clock. It compares the fresh projection with the cached JSON,
reuses its serialized body when equal, and serializes a replacement when changed.
It measures that gate and replacement serialization, not HTTP routing, transport,
ETags, gzip preparation, Keeper load, or visible Dashboard/TUI latency.

Use an isolated workspace with a valid Candle policy and ledger, and freeze an
execution response as input. Remove authentication secrets from any shared input;
the benchmark prints only measurements. Set `MASC_CONFIG_DIR` to the fixture's
configuration directory so it cannot resolve a production override. The benchmark
marks the appraiser available without calling a model; appraisal is outside scope.

```sh
dune exec benchmarks/dashboard_observation/main.exe -- \
  --base-path /tmp/isolated-workspace --snapshot /tmp/execution.json \
  --samples 200 --at 1790640000 --step-s 2
```

Compare identical fixture and snapshot bytes, toolchain, arguments and machine.
Run each candidate in a fresh process to isolate the observation memo. With
half-life off, clock-only reads should retain the prepared body. With nonzero
funding and decay enabled, genuine wallet/supply changes must replace it. Report
both zero-step and advancing-clock controls and preserve raw results. Counts and
latencies from this fixture do not establish a deployed improvement.

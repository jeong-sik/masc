# Home decision aggregation comparison

Compare the old ordered action fold against the current projection-local
index using the installed OCaml interpreter and Mtime bytecode libraries:

```sh
python3 scripts/harness/perf/home_decision_aggregation_probe.py \
  --before-ref fd75478aa3146c4e3910773ad00336dd0adba472 \
  --output-dir /tmp/home-aggregation-new
```

The output directory must be new. `--after-root` selects another checkout.
The runner extracts the baseline from Git and the candidate from that
checkout, copies their actual Home action and Ask identity declarations,
and refuses different declarations. Only the enclosing module is recreated.
It does not compile MASC, launch a TUI, contact a provider or modify a server.

The generated probe checks action identity, duplicate handling and first-seen
order, then measures 30, 300 and 3,000 distinct requests in nine alternating
rounds. Each timed batch includes the five source-list concatenations, index
construction and final immutable result. Input construction, correctness
comparisons and the pre-batch GC compaction are outside the timed region.

Keep `sources.json`, `probe.ml`, `checks.txt`, `raw.csv` and `summary.json`
together. Source, runner, generated probe and installed library hashes bind
the observations. `Mtime_clock.elapsed_ns` provides the monotonic clock;
allocation observations use `Gc.allocated_bytes`.

The summary exposes median, worst and every raw **batch mean**, not individual
request percentiles. This computation excludes approval-source reading,
formatting, repeated projection calls, frame construction and terminal output.
It cannot establish native or installed TUI performance, 300 active Keepers,
or achievement of the 0.1 ms goal. There is no numeric performance gate.

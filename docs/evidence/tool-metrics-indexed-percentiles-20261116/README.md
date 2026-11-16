# Restore indexed percentile selection

`Tool_metrics` retains exact duration counts, but selecting a rank walked the
ascending `Map.to_seq` separately for p50, p95 and p99. The global snapshot cache
is invalidated by every recorded tool call, so an unrelated write can make the
next dashboard read traverse unchanged histories again while holding `metrics_mu`.

This change restores the earlier balanced order-statistics tree. Each immutable
node stores its multiplicity, height and subtree sample count. Insertion and each
rank selection take O(log distinct durations); selection creates no sequence.
The rounded/clamped rank calculation, counts, mean, ordering, cache invalidation,
subscriptions, mutex and public interface remain unchanged. No cache, retention
policy, approximation or configuration is added.

## Source and callers

The baseline is `8269ef535d57e62f6a5913d9651802fd158a49e7`.
Commit `b91ce999cd4d1ae04354be4193f14f46de33b5a1` replaced the prior indexed tree
with the linear map walk. The historical source is its parent, resolved in
[result.json](result.json). The retained
[earlier investigation](../research/2026-08-31-tool-metrics-incremental-percentiles-linux-r1.md)
describes the original mixed-write motivation; its runtime measurements are
historical evidence, not measurements of this candidate.

The restored tree deliberately replaces an equal-comparator key with the
**incoming** value. OCaml 5.5.2 `Map.update` does this when its integer count
changes. `Float.compare` equates signed zeroes and NaN payloads, so copying the
historical first-key behavior would change output float bits. The oracle checks
both insertion orders and explicitly distinguishes the historical behavior.

Handled dispatches record metrics in `server_bootstrap_maintenance.ml`.
`Server_dashboard_snapshot_sources` subscribes to writes and routes the Tools
projection through `Server_dashboard_http_runtime_info`, whose tool summary calls
`Tool_unified.summary_report` and `Tool_metrics.all_stats`. The direct
`/api/v1/tool-metrics` handler also calls that summary. Queues coalesce and readers
share the existing cache, so this does not establish an exact number of full
recomputations per dispatch. `stats_for` also computes a snapshot per call.
The separate `Otel_metric_store.snapshot_named` change does not cover this path.

## Verification

OCaml 5.5.2 on arm64:

- The unchanged public interface and complete final implementation typed against
  the existing real dependency CMIs with fatal warnings 4, 8, 32 and 69; both
  exited 0 with no diagnostics. [actual-typing.json](actual-typing.json) binds
  these checks to source and command-prefix digests. Only the output include
  directory and the unrelated `-open Masc` were adapted for this unwrapped library.
- The native [probe](probe.py) compiles complete current, candidate and historical
  implementations, plus a current-source fused-prefix experiment. `Set_util` is
  real; `Tool_result`, `Tool_dispatch`, `Dispatch_outcome` and `Log.Metrics` are
  explicit fixtures. This is distinct from actual-CMI typing and product linkage.
- **2,550,208 assertions passed.** Exact current/candidate rows, float bits and
  list order match for empty/singleton/duplicate/tied/negative inputs, signed
  zeroes, NaN payloads, infinities, all dispositions and 300 deterministic update
  rounds. Failed replacement preserves the existing cache; writes invalidate it.
- Growing checkpoints over 50,000 ascending, descending, alternating and
  duplicate inputs, 20,000 random inputs and float edges verify strict comparator
  ordering, positive multiplicities, height recurrence, balance, subtree counts
  and every retained rank against the current map oracle. Private tree helpers
  are exposed only by inferred probe interfaces.
- The unchanged `test/test_tool_metrics.ml` ran against the actual candidate
  public interface and implementation: **12/12 passed**, including concurrent
  readers and observer behavior.

## Synthetic read and write costs

Measurements use `Gc.allocated_bytes`; rows report complete timed-loop totals.
Dataset construction is outside read timings. The fused-prefix comparison walks
the map once up to the maximum selected rank, preserving its prefix bound; it
reduces allocation but retains linear selection. `historical` measurements in
the result independently show the same indexed read allocation as this candidate.

| Workload | Current map | Fused prefix experiment | Indexed candidate |
| --- | ---: | ---: | ---: |
| 20 `stats_for` reads, 100k distinct: allocated bytes | 624,670,816 | 253,451,456 | 4,256 |
| Same reads: CPU seconds | 0.038681 | 0.017368 | 0.000010 |
| 20 unrelated writes followed by `all_stats`: allocated bytes | 624,698,768 | 253,471,888 | 18,800 |
| Same mixed operations: CPU seconds | 0.038632 | 0.017987 | 0.000018 |
| 3 replacements, 100k ascending: allocated bytes | 338,721,120 | 338,721,120 | 376,374,552 |
| Same replacements: CPU seconds | 0.060245 | 0.056635 | 0.062785 |
| 3 replacements, 100k random: allocated bytes | 312,989,760 | 312,989,760 | 345,812,664 |
| Same replacements: CPU seconds | 0.233440 | 0.229154 | 0.265868 |
| 3 replacements, 100k samples/3 keys: allocated bytes | 108,000,096 | 108,000,096 | 96,000,360 |

The extra subtree count increases unique/random write allocation by about
10–11% in these fixtures; random replacement CPU increased about 14% in this
process. Duplicate-heavy replacement allocated less. The result also records
20,000 public `record` calls and minimum/middle/high mass distributions. A valid
1,000,000-count minimum plus 5,000 distinct rare keys remains inexpensive: 2,000
private three-quantile calls allocate 4,048,096 bytes currently and 160,096 with
the indexed tree. Warm `all_stats` hits remain unchanged: both sides allocate only
96 bytes of measurement overhead per timed loop.

Each distinct-key tree node retains an additional subtree count compared with
the map node. Resident heap cost and long-running garbage collection were not
measured by these allocation totals.

These are one-process synthetic measurements, not latency distributions, resident
memory measurements, whole-server CPU attribution or installed-runtime proof.
Very short indexed timings approach clock resolution. No Dune build, full CI,
HTTP request, provider call, installation or restart was performed for this unit.

## Reproduce

With OCaml 5.5.2, `ocamlfind`, Yojson, Alcotest and Unix available:

```sh
python3 docs/evidence/tool-metrics-indexed-percentiles-20261116/probe.py \
  --repo . --base 8269ef535d57e62f6a5913d9651802fd158a49e7 \
  --out artifacts/tool-metrics-indexed-percentiles-20261116/reproduction
```

The output directory must be new. Source, helper and unchanged-test hashes are
recorded in [result.json](result.json). Local original captures remain under
`artifacts/tool-metrics-single-walk-20261116/run-6-indexed-final` and
`actual-typing-indexed`; earlier experiments are separate local runs.

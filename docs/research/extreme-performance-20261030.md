# Extreme TUI/server performance: measured baseline and next decisions

The 0.1 ms objective is unmet. A 300-owner installed-source experiment completes
600 durable operations, but `/health/live` has a released-phase p95 of 35.24 ms
and maximum of 8.94 seconds, and MCP status reads time out three times. This is
a latency problem even though the durable workload completes. Evidence and
provenance are in the [scale bundle](../evidence/extreme-performance-20261030/scale/README.md).

The shared runtime and isolated experiments execute installed source d55ec56,
while this investigation starts from checkout 0b18418. The measured native
canonical-function candidate is a third, explicitly extracted source pair;
it has not been installed or observed in the shared server.

## What has been established

The shared-server baseline uses four routes and 20 samples each. Wire p95 is
2.74 ms for health/live, 78.55 ms for shell, 55.86 ms for execution and 1.61 ms
for MCP ping. Every observed minimum also exceeds 0.1 ms. Execution responses
are approximately 871 KB; Python decoding adds a median 9.30 ms. These are
client observations, not OCaml decoder timings. They carry no explicit
semantic/freshness predicates and cannot certify TUI response latency.

A later execution inspection is actor-scoped (admin), not the default public
prepared snapshot. Tasks and Keeper objects dominate its bytes. The TUI's
Keeper roster instead reads `/api/v1/gate/keepers?detailed=true` with workspace
preconditions. Changing execution response size would not automatically repair
the TUI roster path. Compare route contracts and actual consumers before
changing projections, cache keys or freshness policy.

Read-only allocation-profile observations continue to name Add-on original
record reads, request parsing/canonicalization and receipt reconstruction.
The two cumulative observations differ by 45,236 allocation samples, with no
additional dropped samples between them. Existing lifetime drops are large
(41,393,109); retained pending events and top-30 truncation prevent treating
the tables as complete, unbiased allocation attribution. No reset, profiler
restart or heap-root walk was requested. This guides investigation; it does
not establish CPU or end-to-end causation.

One pure candidate skips two sorts when object keys already strictly increase.
The [native function bundle](../evidence/extreme-performance-20261030/canonical/README.md)
retains all three experiments, including rejected/unordered regressions.
Sorted 300-field batch means improve substantially and allocations decrease
66.68%; late inversion and duplicate cases cost extra scans. No request is
trusted merely because it is called canonical: non-ordered input keeps the
original duplicate check and child-error order. This reduces one measured
component without changing durability or adding mutable product state.

## Measurement matrix still required for completion

Use 100 us as the explicit target for every relevant boundary below. Report
per-call distributions, failure/retry denominators, data size, CPU, allocation
and I/O; a batch mean below target is insufficient. Separate ready/warm/cold,
stale/partial/failed results and controlled 30/300 owner populations.

| Boundary | Current evidence | Remaining proof |
| --- | --- | --- |
| TUI input decision, decode, state application, build, present | Installed TUI identifies d55ec56; no new timing run | Real native requests/state decisions and phase timings, physical display scope separate |
| HTTP and MCP | Limited live wire baseline; isolated health/status | Route-specific semantic/freshness predicates, aligned server stages, tails under controlled load |
| Markdown/HTML/file I/O | Original-record allocation clues | Read/hash/parse/commit attribution, growth and replacement, durable before/after |
| SQLite queue operations | 60/600 exact durable outcomes | Admission, lookup, commit/checkpoint distributions and duplicate/loss checks |
| Keeper-to-Keeper calls and broadcast | Admin-submitted queue workload only | Real peer authority, fan-out, per-recipient delivery and fairness |
| Multiple Feature Add-on lanes | Pure canonicalization microexperiment | Actual concurrent lane work, reply/owner isolation and retained receipts |
| OCaml multicore | Existing live pools: 8 general + 2 read domains on 16 CPUs | Same semantic workload across core budgets, CPU/wall/GC and queue wait together |

## Architecture experiments to decide from measurements

1. Trace the 300-owner status stalls and model-release burst with aligned
   operation, pool admission, I/O and scheduler events. Existing Server-Timing
   dispatch is elapsed time; split waiting from CPU before selecting a fix.
   Keep volume-inventory cost visible and isolate it experimentally, rather
   than attributing an overlapping burst to it without a counterfactual.
2. Keep decision state and durable ownership authoritative while moving repeated
   projection work to immutable producer snapshots or revisioned indexes.
   Any incremental file path must prove append continuity, replacement and
   recovery under RFC-0437/RFC-0474. An old stat or cached display must not
   authorize a new effect or hide an unreadable original.
3. Measure bytes and decoding on the actual TUI route. Consider revision-bound
   deltas/subscriptions only after defining restart, missed-update and full-read
   recovery semantics. A small response with omitted required state is not a win.
4. Use the existing domain budget and cancellation-aware pools. Vary core
   allocation in isolated runs; adding domains or parallelizing serialized
   durable commits is not itself evidence of improvement. Preserve worker
   settlement, cancellation, fairness and exactly-once effect boundaries.

The earlier RFC-0474 work targets elimination of multi-second stalls and has
already introduced pool budgeting and incremental retained-read improvements.
That evidence is a starting point, not proof of the stricter current goal.
This investigation remains open; there is no deployment, whole-product
performance verdict or goal-completion claim in this unit.

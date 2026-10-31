# Extreme TUI/server performance: measured baseline and next decisions

The 0.1 ms objective is unmet. A 300-owner installed-source experiment completes
600 durable operations, but `/health/live` has a released-phase p95 of 35.24 ms
and maximum of 8.94 seconds, and MCP status reads time out three times. This is
a latency problem even though the durable workload completes. Evidence and
provenance are in the [scale bundle](../evidence/extreme-performance-20261030/scale/README.md).

The earlier shared-server baseline and isolated server experiments used installed
source d55ec56, while this investigation started from checkout 0b18418. The measured native
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

## Traced stalls and file-writer counterfactuals

The [runtime-events bundle](../evidence/extreme-performance-20261030/runtime-events/README.md)
retains a separate instrumented 300-owner run: 600 durable operations, one failed
health sample out of 2,261, released successful-read p95 141.554 ms and maximum
10.606 seconds. The old consumers record long domain-0 intervals around I/O but
cannot causally attribute one HTTP stall or certify exclusive CPU. The new
ready/stop/flush protocol was separately qualified with two native owners.

`Fs_compat.append_jsonl` encodes and writes on the caller domain's system thread.
The [OCaml 5.5 manual](https://ocaml.org/manual/5.5/parallelism.html#s:par_systhread_interaction)
explains that OCaml execution remains serialized within one domain. That makes
main-domain CPU contention plausible, not proven for these HTTP outliers.
`Systhread_host` already moves eligible work to another domain, but masc_core
depends on fs_compat: directly calling that core module from Fs_compat would
create a dependency cycle. Placement needs an appropriate lower-level boundary
or changes at the owning caller, after measuring its actual critical path.

The next [file-cache study](../evidence/extreme-performance-20261030/fd-cache/README.md)
compares the actual cache module against two standalone counterfactuals.
Removing caching regresses a 30-path working set about fivefold. Moving only
inode validation outside the global mutex has mixed outcomes. The first
parallel study puts encoding inside a per-path mutex, differing from the product.
A separate corrected run preserves product ordering and improves normalized
small-row/eight-worker/hot-cache wall time about 2.30-fold while CPU rises 4.4%;
other shapes regress and all allocate more. Its compiled-executable digest and
final-equality receipt apply only to the new run; older runs lack these digests.
Per-case assertions are visible in source, but Python optimization flags were
not captured, so those checks have no separate execution receipt.
The prototype is retained for investigation and
is not applied to production. The parallel values are inverse throughput,
not individual action latency or evidence of meeting 0.1 ms. Both rejected
approaches remain visible with CPU, wall, allocation and exact-byte readback.

## Added TUI and DAW scope

The current objective explicitly includes scrolling, Page Down, surface changes,
Draw, DAW features and visible flicker. DAW and Draw were confirmed as separate
requirements. An earlier unretained installed self-report was `8c08d4c…`; the
subsequent retained receipt self-reports `f06ab8f…` with a different binary
digest. These are separate observations of a moving shared installation. The
earlier d55ec56 server observations establish neither TUI behavior nor timing.

The [chat prefix-index component](../evidence/extreme-performance-20261030/tui-chat-prefix/README.md)
removes repeated scans of a measured newest suffix without adding mutable fields.
Its viewport/body-anchor adapter passes 113,100 decision checks; a warm
30,000-entry component improves substantially, with small cold-path and large
single-entry negative observations retained. Neither this adapter nor source
parsing proves actual TUI response or visible smoothness. The large single-entry
materialization/fold remains a separate bottleneck candidate.

DAW source is in `tools/alphatex/music-workbench.mjs`, `sequencer-tui.mjs` and
`arrangement-tui.mjs`. These views erase the entire viewport before rewriting it;
the piano roll also scans the complete note list separately for every visible
pitch. The [DAW component study](../evidence/extreme-performance-20261030/daw-piano-roll/README.md)
now measures extracted piano-roll calculations with explicit synthetic inputs.
Style-array comparison and frame-local note grouping reduce observed CPU/wall
for multiple pitch rows. An adversarial one-row regression caused a structural
single-scan correction; all five runs and remaining negative observations are
retained. The final 48-row/30k/onscreen-uniform component improves 5.408→1.069 ms
but its per-call p95 is 2.301 ms. This is not whole DAW latency, allocation,
audio timing or an observed physical flicker cause.
[Ghostty's synchronized-output documentation](https://ghostty.org/docs/help/synchronized-output)
explains why intermediate large redraws can flicker. A DEC 2026/differential
presentation experiment must preserve terminal policy, recovery and child-view
ownership; source markers alone will not prove a visible improvement. DAW
edit/navigation, audio/MIDI timing and redraw costs require separate observations.

## Actual native TUI under owned Keeper load

The [native TUI owner-scale bundle](../evidence/extreme-performance-20261030/native-tui-owners/README.md)
adds exact-source 5297349 native TUI/server runs at 2/30/300 real owner counts
with a scripted local provider, 4/60/600 durable outcomes, 85/93/109 Build and
Present samples, and raw stage/clock/omission checks. The shared runtime was
not restarted or loaded. This is a candidate observation, not before/after
improvement or external-provider/peer/physical-display proof.

The 300-owner keeper-list Build cohort has p50 4.800 ms and p95 5.608 ms
(14 samples); chat Build has p50 0.253 and p95 0.579 ms (58 samples). The
released health cohort retains p95 47.815 ms and maximum 8.269 seconds. Thirty-
owner Present has a separate 13.863 ms outlier mostly outside write/flush;
300-owner Present's worst is instead mostly flush. No single causal explanation
follows from those different outliers.

The visible Keeper window is already bounded in source. Next profiling should
inspect repeated fleet-wide `keeper_reading`/model preparation and joins, rather
than assuming all offscreen rows are rendered. UI loader/application cardinality
and actual scroll state remain unobserved. In the measured source, the native
residual diagnostic subtracts nested stages twice. The
[diagnostic correction](../evidence/extreme-performance-20261030/frame-stage-union/README.md)
uses immutable interval unions and matches an independent endpoint oracle on all
287 recorded Builds. Seventeen focused copied-module tests passed; this is not a
new native TUI execution or a frame-latency gain. Union-uncovered wall is not
exclusive CPU.
Native elapsed and Python perf-counter clocks remain separate, so input writes
are not mapped to frames. The control native build at direct parent b004188
completed and its downloaded TUI digest/embedded source were verified. That
artifact provides no server; a performance execution/comparison remains future
evidence.

## Measurement matrix still required for completion

Use 100 us as the explicit target for every relevant boundary below. Report
per-call distributions, failure/retry denominators, data size, CPU, allocation
and I/O; a batch mean below target is insufficient. Separate ready/warm/cold,
stale/partial/failed results and controlled 30/300 owner populations.

| Boundary | Current evidence | Remaining proof |
| --- | --- | --- |
| TUI input decision, decode, state application, build, present | Candidate 5297349 native 2/30/300 owner phase samples; input application/scroll position unobserved | Real native requests/state decisions and phase timings, physical display scope separate |
| DAW edit/navigation, piano roll, playback and presentation | Paired extracted-loop wall/CPU; 4 existing style and 63 controller/editor checks | Real input/state timing, allocation, audio/MIDI deadlines and physical flicker |
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

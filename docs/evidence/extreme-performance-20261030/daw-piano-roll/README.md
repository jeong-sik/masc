# DAW piano-roll calculation study

Both DAW features and Draw are explicit requirements. This unit reduces two
measured calculation costs: repeated full-note scans for every visible pitch,
and per-cell SGR-array serialization just to compare styles. The 0.1 ms goal
remains unmet. It establishes neither whole-DAW latency, actual keyboard
response, audio/MIDI timing nor visible flicker improvement.

## Candidate and source scope

Multiple visible pitch rows share one frame-local `Map.groupBy` over notes in
the visible pitch/time window. Notes retain their source object and order;
original left/right cell bounds still apply. With exactly one visible pitch
row, grouping has no reuse: the final candidate keeps the original single
source scan and pitch guard. No new mutable UI field, persistent cache,
generation counter or configuration is introduced. Temporary grouped arrays
belong only to that calculation. The private coalescer compares its actual
callers' atomic string SGR arrays directly, avoiding joined comparison strings.
It is not claimed byte-equivalent for arbitrary style encodings such as one
string containing semicolons versus several strings.

[ECMAScript's grouping algorithm](https://tc39.es/ecma262/multipage/keyed-collections.html#sec-map.groupby)
forms groups from the input iterator. Node introduced array grouping with V8
11.8 in its [Node 21 release](https://nodejs.org/en/blog/announcements/v21-release-announce).
The package already requires Node >=22. Actual executions here used **26.3.0**;
there is no minimum-version execution receipt. `provenance.json` distinguishes
whole-file hashes from the exact executed v5 grid and two style functions.

## Experiment and retained negative results

Each program extracts the actual piano-roll loop and calls it with explicit
synthetic inputs; `String` substitutes for Tonal pitch labels. Real
`cellSegments` is copied, with declared counterfactuals. Header/harmony analysis,
editor projection, scheduling, final fit/output construction, writes, transport
and physical display are outside this component. A checksum consumes results
without asserting screen text, layout or row order. These are performance
observations, not functional equivalence tests.

- v1: six balanced three-variant orders compare original, all-pitch grouping,
  and visible-pitch grouping. Grouping alone has small-input regressions and a
  24-row/30k-uniform all-grouping wall regression. All observations are retained.
- v2: eight balanced four-variant orders separate pitch grouping and direct
  style comparison. Much empty-grid cost is in joined style comparisons.
- v3: six balanced orders add time-window filtering. Its mostly-outside-time
  shapes improve substantially, but filtering costs more than pitch-only
  grouping in some offscreen cases. This is a predecessor, not the final v5
  source. Its 48-row/30k-uniform wall 2510.5→368.2 us is not a final-candidate or
  whole-DAW performance claim.
- v4: adversarial inputs put every onset in the visible time window and add a
  13-row terminal (one pitch row). The generic grouping candidate regresses
  13-row/30k/one-pitch wall 1773.5→2170.9 us and CPU 1243.2→1829.8 us. This
  concrete negative result caused the single-row algorithm correction.
- v5: the final source is measured in those adversarial shapes. Its one-pitch
  13-row/30k wall is 1391.0→1289.4 us and CPU ratio 0.97. The same-size uniform
  case is 184.9→186.3 us (about +0.8% wall), CPU ratio 0.97. No uniform speedup
  claim is made. Raw differences across processes are not paired comparisons.

## All final-candidate observations

Wall is the median of batch means; CPU is the ratio of median batch CPU means.
The last column is the 95th percentile of recorded individual **component**
calls, including timer instrumentation, not keyboard-to-display latency. Every
shape has six balanced variant orders; v5 has 96 calls per variant at 30k and
384 otherwise. Shared-host scheduling, JIT and GC are not controlled away.
The final 48-row/30k/onscreen-uniform component improves 5407.7→1068.8 us but
its individual-call p95 remains 2300.9 us. Dense one-pitch inputs remain costly.

| Terminal rows | Notes | Distribution | Before wall us | Final wall us | CPU ratio | Final call p95 us |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 13 | 0 | empty | 25.9 | 18.8 | 0.458 | 24.2 |
| 13 | 30 | onscreen-one-pitch | 23.8 | 17.9 | 0.571 | 48.0 |
| 13 | 30 | onscreen-uniform | 27.0 | 8.0 | 0.333 | 12.6 |
| 13 | 300 | onscreen-one-pitch | 60.9 | 53.4 | 0.462 | 110.5 |
| 13 | 300 | onscreen-uniform | 51.3 | 26.9 | 0.343 | 82.7 |
| 13 | 3000 | onscreen-one-pitch | 134.1 | 96.5 | 0.812 | 275.3 |
| 13 | 3000 | onscreen-uniform | 79.2 | 42.0 | 0.332 | 108.0 |
| 13 | 30000 | onscreen-one-pitch | 1391.0 | 1289.4 | 0.974 | 2190.8 |
| 13 | 30000 | onscreen-uniform | 184.9 | 186.3 | 0.971 | 400.0 |
| 24 | 0 | empty | 228.8 | 99.6 | 0.478 | 232.4 |
| 24 | 30 | onscreen-one-pitch | 205.3 | 95.7 | 0.548 | 192.8 |
| 24 | 30 | onscreen-uniform | 261.4 | 102.5 | 0.435 | 307.0 |
| 24 | 300 | onscreen-one-pitch | 440.7 | 176.2 | 0.477 | 427.6 |
| 24 | 300 | onscreen-uniform | 310.5 | 158.8 | 0.514 | 429.7 |
| 24 | 3000 | onscreen-one-pitch | 550.1 | 389.3 | 0.682 | 806.8 |
| 24 | 3000 | onscreen-uniform | 609.1 | 214.3 | 0.336 | 605.2 |
| 24 | 30000 | onscreen-one-pitch | 2834.0 | 2060.5 | 0.796 | 3844.6 |
| 24 | 30000 | onscreen-uniform | 1784.1 | 500.6 | 0.278 | 836.6 |
| 48 | 0 | empty | 634.4 | 308.4 | 0.505 | 476.9 |
| 48 | 30 | onscreen-one-pitch | 603.1 | 311.1 | 0.506 | 517.0 |
| 48 | 30 | onscreen-uniform | 646.3 | 312.5 | 0.478 | 547.8 |
| 48 | 300 | onscreen-one-pitch | 693.5 | 331.0 | 0.482 | 562.9 |
| 48 | 300 | onscreen-uniform | 713.4 | 359.1 | 0.481 | 614.4 |
| 48 | 3000 | onscreen-one-pitch | 1065.6 | 491.0 | 0.461 | 814.8 |
| 48 | 3000 | onscreen-uniform | 1166.5 | 407.8 | 0.340 | 729.2 |
| 48 | 30000 | onscreen-one-pitch | 5401.4 | 2315.5 | 0.406 | 3409.7 |
| 48 | 30000 | onscreen-uniform | 5407.7 | 1068.8 | 0.204 | 2300.9 |

[Node process CPU](https://nodejs.org/api/process.html#processcpuusagepreviousvalue)
can include concurrent runtime work. GC entries from
[PerformanceObserver](https://nodejs.org/api/perf_hooks.html#garbage-collection-gc-details)
cover the whole process including warmup. Per-batch `heapUsed` deltas are only
heap observations, **not allocated-byte counts**, and GC is not attributed to a
variant. Exact allocation remains unmeasured. `execArgv` is recorded; inherited
Node environment was not captured, so default-runtime identity is not certified.

## Behavior checks and limits

Four existing terminal-style checks pass at the unchanged final style hash;
their receipt predates the single-row sequencer correction. Existing selected
controller/editor tests pass **63/63** after the final correction, including
selection, note edits, source timing, undo/save, playback requests and async
close ownership, with owned I/O substitutes. The earlier 63/63 predecessor
receipt is kept separately. No new screen/layout tests were added.
Independent read-only source review found no new correctness P0–P2 in its scope
and checked the v5 fragment/negative-result correction. It is not formal GitHub
approval or a substitute for real UI/audio evidence.

No user project was edited and these runs opened no audio device. The view
still erases and rewrites the viewport. Actual input/Build/Present traces,
allocation attribution, audio/MIDI deadlines, differential/synchronized
presentation and physical flicker observation remain separate work.

To reproduce, copy a complete version into a **new ignored output directory**
and run `node bench.mjs`, retaining fresh executable/source hashes, stdout,
stderr and exit receipt. Do not write into this retained bundle or reuse its
historical identities as new proof. These component scripts require only Node
and the copied local modules, not package installation or audio hardware.

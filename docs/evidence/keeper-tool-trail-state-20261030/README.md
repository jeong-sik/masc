# Keeper tool-trail argument accumulation

Baseline: `810aedacf089b0e1650a4887ad39359b09328ee5`.
Candidate source and tests: `dbece77e24688f95960e027f195dc37f7c992a4f`
(source blob `2c18678434e13599da79e9b988e7f6bc0892d925`, test blob
`da44a7af5827457f72f2525a6a6ffdd03f11c811`). The candidate accumulates
argument fragments without copying the preceding string on every delta and
compacts them on `Tool_call_end`. An end does **not** add a closed state:
duplicate ends, later deltas and snapshots keep their prior behavior.

The collector uses `(stream_scope, block_index)` for start, delta, snapshot and
end lookup. The existing provider call/message correlation checks apply to
**admitted name changes**, not to every argument or end event. This change
does not add such validation. Current Slack and Discord adapters consume the
collector on their subscriber and render its trail when a turn finishes.

## Scope and reproduction

The original and candidate production `.ml` files and their public `.mli` were
compiled with OCaml 5.5.1, arm64 macOS 26.6.1, `ocamlopt -O3` (no flambda),
against actual `Keeper_text_processing` and `Secret_patterns` source. The
event type is the reduced shim in this bundle; `Observability_redact` is a
shim with the same `Secret_patterns.redact_text` delegation used by the real
function. Both versions passed the same 33 Alcotest cases, including the new
interleaved snapshots, split UTF-8, repeated end, later delta and admitted-name
correlation cases. A seeded differential comparison checked rendered rows,
counts and appended replies after each of 80,000 mixed events, including end
events. These are isolated results, not a whole-program build or live test.

From a checkout containing the commits above:

```sh
python3 docs/evidence/keeper-tool-trail-state-20261030/reproduce.py \
  --baseline 810aedacf089b0e1650a4887ad39359b09328ee5 \
  --candidate dbece77e24688f95960e027f195dc37f7c992a4f \
  --out artifacts/keeper-tool-trail-state-20261030/reproduction
python3 docs/evidence/keeper-tool-trail-state-20261030/measure_profiles.py \
  artifacts/keeper-tool-trail-state-20261030/reproduction/compare/equivalence_bench \
  artifacts/keeper-tool-trail-state-20261030/reproduction/compare/profiles.csv
```

Reproduction requires local `yojson`, `re`, `alcotest` and `unix` packages;
the RSS helper uses macOS `/usr/bin/time -l`. It writes a new run under
`artifacts/` and does not replace the captured samples here.

## Captured comparisons

[`samples.csv`](samples.csv) contains seven alternating samples for each
in-memory workload. Delta-final workloads send 64-byte fragments forming a
valid JSON argument, emit an end, and render once; counts below are the median
for the stated iterations. Events are prebuilt and the producer, journal,
network, and real connector are excluded.

| Workload | CPU old → new | Wall old → new | Allocated bytes old → new |
| --- | ---: | ---: | ---: |
| 256 deltas, 30 iterations | 16.046 → 5.071 ms | 16.590 → 5.071 ms | 66,202,400 → 3,968,020 |
| 16 deltas, 500 iterations | 6.261 → 6.469 ms | 6.276 → 7.001 ms | 8,972,100 → 5,652,100 |
| 256 snapshots, 30 iterations | 0.259 → 0.264 ms | 0.258 → 0.263 ms | 398,976 → 646,656 |
| 256 deltas with render after every event, 4 iterations | 93.790 → 96.490 ms | 114.459 → 203.708 ms | 49,462,300 → 52,792,400 |

The short timing samples are noisy; the repeated-render and snapshot cases are
counterexamples to a universal improvement. These are synthetic collector
measurements, not a claim about full Keeper request latency or throughput.

[`retained.csv`](retained.csv) measures live OCaml heap words after a full
major collection while one synthetic trail stays reachable; the sender drops
each fragment after delivery. With 4,096 × 64-byte fragments, the median before
end is 32,813 → 53,292 words; after end it is 32,813 → 32,816. With 128 ×
4,096-byte fragments the corresponding medians are 65,581 → 66,476 before end
and 65,581 → 65,584 after end. This is retained live heap, not peak memory or
RSS; it deliberately excludes other owners of the same bytes.

[`profiles.csv`](profiles.csv) contains five alternating **separate-process**
measurements for each condition with 24 calls, 64 × 4,096-byte fragments per
call, and at most eight displayed rows. For all calls ended and final render
performed, the post-GC live-heap median is 788,596 → 788,668 words and the
whole-process maximum RSS median is 27,623,424 → 18,415,616 bytes. The RSS
maximum includes initialization, all accumulation, compaction, rendering,
and GC; it does not isolate the instant of end or prove a production peak.
Before end, the same fixture retains 787,033 → 797,761 words.
The CSV is a line-ending-only derivative of
[`profiles.original.csv.gz`](profiles.original.csv.gz); decompressing that
archive yields the captured CRLF bytes with SHA-256
`4e69640c8c2dfc00c9bf971e37fb5541cce222d1b5751046da6fc792739e973d`.

The server's streaming redactor can coalesce tool arguments at line or bounded
flush boundaries; the bridge also retains argument fragments. The isolated
sender here implements neither, so its 64-byte case cannot be converted into
a real connector heap estimate. Fragment cells remain live until end,
snapshot replacement or collector disposal, and end can transiently hold the
fragments, their reversed list and the combined string together. Neither the
actual connector, its event queue nor a real Keeper turn was measured.

## Earlier candidate

[`initial-candidate.ml.txt`](initial-candidate.ml.txt) is the earlier source
without end compaction, with its final empty line removed. The exact source
bytes are in [`initial-candidate.original.gz`](initial-candidate.original.gz):
their Git blob is `eef229b8de5fd6ed6e15d43091491124dab4332e` and SHA-256 is
`37e6b2bb7315db44a2d150d48740826b403f44eb7940f413a168c308196d923b`.
[`initial-samples.csv`](initial-samples.csv) and
[`initial-retained.csv`](initial-retained.csv) retain its raw results, which
motivated the added compaction. The saved initial harness is reproducible with
`--scenario initial --candidate-file docs/evidence/keeper-tool-trail-state-20261030/initial-candidate.ml.txt`;
it remains a synthetic comparison and is not the final candidate's data.

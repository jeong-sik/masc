# Chat composer state: isolated comparison

This record compares the input module before and after keeping draft text and
revision together and recognizing one-byte input boundaries. It is not a TUI
runtime or installation measurement.

The original input is from `0b18418111a533b3dc10c33b8811b1d058f136fe`
(input blob `d21e8cd0e11a2350927b352849bff41e1c3f1f41`, SHA-256
`052122c48a3d8af061bf402befc5af9e23fd83cfe33e756ae7813250172fb0ed`).
The measured input is from `62c30fbc32c79578b42ac1bf5945e1d9ee9f49a0`
(input blob `a40f2a0e8ee3295b5791dc32669e2de257fdb730`, SHA-256
`3e550866076d101ef104e074b94221e3f760dd0e641048d948a8004fd5400005`).
Both copies used the actual layout, grapheme segmentation, frame and string
utility modules from the original tree, whose contents are unchanged in the
candidate. The 2026-10-30 run used OCaml 5.5.1 on a shared Darwin arm64 host,
macOS 26.6.1, Uuseg/Uucp 17.0.0 and Alcotest 1.9.1. The comparison was linked
with `ocamlfind ocamlopt`; it did not run Dune or compile the whole application.

## Behavior

The candidate's nine input-module Alcotest cases passed. The seeded
[differential harness](equivalence.ml.txt) compared 400,000 mixed actions,
including text, cursor, revision validity, CRLF, Unicode, ANSI and invalid
bytes. It also checked all 9,409 pairs of printable ASCII, LF and tab against
the real layout boundary function. These non-exception comparisons matched.
The [voice seam](voice_consumer.ml.txt) contains the append statements extracted
from the old and new `Voice_transcribed` branches; its 30 cases matched for
contents, cursor and revision invalidation. It stubs the surrounding state and
does not execute an asynchronous UI event, draft persistence or send-on-stop.

The [failure injection](failure.ml.txt) uses a deliberately stubbed
[layout](failure_layout.ml.txt) that raises on segmentation. It demonstrates
the intentional exception difference: the old insert can leave new text with
the previous cursor, while the candidate keeps the previous text and cursor;
both invalidate the old revision. This is an injected failure, not an observed
production exception. The old voice path could similarly retain only its added
separator after a failure; the new combined edit keeps the preceding draft.

## Timings and allocation

The raw seven alternating-order samples are [bench-final.csv](bench-final.csv)
and [voice-final.csv](voice-final.csv); their sources are [bench.ml.txt](bench.ml.txt)
and [voice_final_bench.ml.txt](voice_final_bench.ml.txt). Each comparison runs
both implementations in one process. The general benchmark isolates the actual
layout pieces cache per sample. Every sample calls `Gc.full_major` before the
measurement; allocated bytes are differences in `Gc.allocated_bytes`, CPU is
`Sys.time`, and wall is `Unix.gettimeofday`. The figures include harness and
counter overhead. Values below are medians across seven samples, not paired
differences. There was no explicit warmup. Wall time can be affected by the
clock and other work on the host; the shortest timings are especially noisy.

| Workload | CPU ms, old → new | Wall ms, old → new | Allocated bytes, old → new |
| --- | ---: | ---: | ---: |
| 400 drafts × 64 ASCII inserts | 13.695 → 1.396 | 14.845 → 1.572 | 102,131,296 → 5,680,096 |
| 200 drafts × 64 Hangul inserts | 50.970 → 49.269 | 55.993 → 53.599 | 125,688,352 → 126,847,648 |
| 400 left/right pairs in a 4,096-byte ASCII draft | 61.361 → 0.016 | 73.437 → 0.014 | 367,674,704 → 12,648 |
| 400 left/right pairs in a 1,024-character Hangul draft | 4.810 → 4.727 | 5.127 → 5.572 | 20,025,048 → 20,025,200 |
| 4,000 drafts × 20 small standalone appends | 1.325 → 1.402 | 1.323 → 1.401 | 5,952,096 → 8,608,096 |
| 1,000 mixed edit sequences | 0.808 → 0.746 | 0.808 → 0.744 | 3,694,976 → 3,326,976 |
| 12 inserts of 64 KiB ASCII | 56.871 → 0.901 | 56.946 → 0.923 | 89,723,120 → 1,641,488 |

The CSV calls the 20-append scenario `voice_append_ascii`; it is a synthetic
standalone-append stress case, not the current voice caller. Its allocation
increased 44.6% and its median CPU and wall times increased about 5.8% and 5.9%.
Hangul typing allocation increased 0.92%; Hangul navigation's measured median
wall time increased 8.7% in a short noisy sample. These observations limit any
general performance claim.

The caller-shaped voice comparison measures the previous one or two appends
against `append_separated`, with drafts allocated before the sample:

| Draft prefix | Count | CPU ms, old → new | Wall ms, old → new | Allocated bytes, old → new |
| --- | ---: | ---: | ---: | ---: |
| empty | 40,000 | 1.839 → 1.580 | 1.837 → 1.578 | 2,240,096 → 3,520,096 |
| 5 bytes | 40,000 | 2.283 → 1.758 | 2.284 → 1.820 | 3,840,096 → 3,840,096 |
| 4,096 bytes | 4,000 | 4.932 → 3.242 | 5.320 → 3.513 | 33,120,096 → 16,736,096 |

For an empty draft the new path allocates 32 additional bytes per utterance in
this harness. These microbenchmarks do not establish live input latency, total
application CPU or behavior on another machine. No production TUI was run.

## Fresh reproduction

From a checkout containing both source commits, with the listed compiler and
packages available, choose a new output directory under ignored `artifacts/`:

```sh
sh docs/evidence/tui-composer-state-20261030/reproduce.sh artifacts/FRESH-composer
```

The script compiles the exact modules and retained harnesses into that new
directory, writes fresh results there, and refuses to overwrite an existing
directory. Its output is a new run and cannot establish the original timings.
The retained CSV files are the original sample bytes, not the fresh run.

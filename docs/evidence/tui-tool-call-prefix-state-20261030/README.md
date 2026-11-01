# TUI tool-call list updates

Baseline: `a999f3f537571bd0d4be40e3ed1bc3a031419f77`.
Candidate source and test commit: `6c5546490cae7fb40b13b7d09ddb320887f75fbe`
(source blob `6128b292303114b70d3d8c2ab6552e8d3999d1e0`, test blob
`5092fa9cc57355f0bac39de11f4373ecaa5f200f`). A transcript previously rebuilt
the entire immutable list to update a local call. The new walk reuses the
unchanged suffix if it contains no further matching local ID; when it does,
the fallback retains the original behavior of updating every matching ID.
This does not create a second mutable call index or change occurrence lookup.

## Reproduction and scope

With OCaml 5.5.1 on arm64 macOS 26.6.1, `ocamlopt -O3` (no flambda),
[`reproduce.py`](reproduce.py) extracts the exact old and new update functions
from the commits, and the unchanged occurrence lookup and correlation helpers.
It compiles them with synthetic call, occurrence and transcript records:

```sh
python3 docs/evidence/tui-tool-call-prefix-state-20261030/reproduce.py \
  --baseline a999f3f537571bd0d4be40e3ed1bc3a031419f77 \
  --candidate 6c5546490cae7fb40b13b7d09ddb320887f75fbe \
  --out artifacts/tui-tool-call-prefix-state-20261030/reproduction
```

The first harness compared 100,000 seeded unique and duplicate-ID lists,
including callback order and exceptions, and updated the oldest element in a
500,000-node list without stack overflow. The second compared 100,000 seeded
occurrence lookups and updates, including missing and conflicting identities,
callback order and resulting records. Both passed. These are isolated tests of
the extracted functions against shims; they are not a whole TUI build.

The repository test added with the change exercises 24 interleaved tool
occurrences, including old and new result owners and draw-cache invalidation.
It has not been executed locally; the focused TUI CI suite is requested
separately. No actual terminal, user interaction, live Keeper, or memory peak
was observed.

## Captured performance samples

[`occurrence-samples.csv`](occurrence-samples.csv) contains seven alternating
samples per case. Each repeats a lookup and update against one synthetic list;
the times include occurrence lookup, correlation checks and update, but not
the rest of an event, rendering, network or a terminal frame. Median results:

| Case | CPU old → new | Wall old → new | Allocated bytes old → new |
| --- | ---: | ---: | ---: |
| 16 calls, newest, 50,000 iterations | 2.192 → 0.955 ms | 2.192 → 0.955 ms | 26,400,096 → 6,400,096 |
| 256 calls, newest, 5,000 iterations | 2.737 → 1.647 ms | 2.746 → 1.656 ms | 31,440,096 → 640,096 |
| 256 calls, oldest, 5,000 iterations | 5.367 → 5.676 ms | 5.367 → 5.681 ms | 31,440,096 → 31,240,096 |
| 256 calls, duplicate ID, 5,000 iterations | 2.881 → 4.467 ms | 2.885 → 4.466 ms | 31,680,096 → 31,680,096 |

These short synthetic timings do not establish total TUI CPU or frame latency.
The duplicate case is defensive: real local IDs are created by an increasing
counter and the list retains those calls. The fallback still matters to
preserve the previous operation's behavior if duplicates occur. The oldest
and duplicate cases show that CPU can increase. [`replace-samples.csv`](replace-samples.csv)
isolates the replacement itself; the separately retained run-1 CSVs contain
the earlier samples before the duplicate benchmark was added.

## Rejected candidate

[`rejected-first-match.ml.txt`](rejected-first-match.ml.txt) reused the suffix
immediately after the first match. It was rejected because an input containing
two equal local IDs updated only the first, whereas the original updates both.
[`rejected-first-match-samples.csv`](rejected-first-match-samples.csv) records
that preliminary candidate's timings, which are not the final candidate's
results. Add `--rejected` to the reproduction command to run the saved
two-duplicate counterexample.

# TUI spill placeholder lookup

Baseline: `f42c92edb40228dcbf280401cea25358482ac4db`.
Candidate source and tests: `f28c22cb9781bd9de2d8b167ae49b61045e23ce1`
(spill module blob `3d5891054a9d54d42dbfb76c01020b8e2f73a42c`, state
module blob `ba546848a8666a00b674fd0069fa128bf1c7ff20`, test blob
`5c3ee007a0984f901772cccf85d3a79385a2d99c`).

Searching a draft for a spill line used to allocate a candidate substring at
every byte position. The same search was also used by draft saving merely to
answer whether the line existed, constructing a replacement string that was
immediately discarded. The candidate uses the existing `String_util` byte
search and a presence projection. The first exact marker remains authoritative;
replacement and surrounding bytes are unchanged. This does **not** address
multiple large pastes overwriting the single draft spill slot, nor does it
establish request ownership of staged files.

## Reproduction and scope

On arm64 macOS 26.6.1, OCaml 5.5.1 `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) compiles the exact old and new spill modules and
their respective public interfaces and repository tests. The old eight tests
and new ten tests passed. The two new tests cover the first of repeated exact
markers, surrounding arbitrary bytes, and an incomplete marker. Both versions
also passed a separate check of the exact `message_spill_in_text` function
extracted from their respective state modules.

```sh
python3 docs/evidence/tui-spill-placeholder-state-20261030/reproduce.py \
  --baseline f42c92edb40228dcbf280401cea25358482ac4db \
  --candidate f28c22cb9781bd9de2d8b167ae49b61045e23ce1 \
  --out artifacts/tui-spill-placeholder-state-20261030/reproduction
```

These are isolated compilations, not a Dune build or full TUI: the layout
dependency is a shim using the `composer_max_rows` constant extracted from
each revision, while the real unchanged naming and `String_util` sources are
compiled. The state check supplies a minimal record for the extracted
function. The [`harness`](harness.ml.txt) compared the old and new replacement
result and presence result on 100,005 seeded cases including arbitrary bytes,
missing/partial/repeated markers and marker-like input. It does not exercise
draft switching, queue admission, delivery, or a real terminal.

## Captured measurements

[`samples.csv`](samples.csv) retains seven alternating-order samples per case
and operation, each comprising 1,500 calls. The two presence paths correspond
to the old discarded replacement and the new presence check. Selected medians:

| Case and operation | CPU old → candidate | Wall old → candidate | Allocated bytes old → candidate |
| --- | ---: | ---: | ---: |
| 8 KiB prefix, marker at end; presence | 110.183 → 24.629 ms | 110.363 → 24.676 ms | 1,009,416,096 → 1,620,096 |
| 8 KiB prefix, marker at end; replacement | 109.651 → 25.665 ms | 109.840 → 25.731 ms | 1,009,416,096 → 26,316,096 |
| 8 KiB without marker; presence | 104.673 → 24.251 ms | 104.843 → 24.265 ms | 977,016,096 → 1,596,096 |
| Repeated near-markers; replacement | 108.399 → 38.774 ms | 108.645 → 38.833 ms | 992,376,096 → 1,596,096 |
| Short text, marker at start; replacement | 0.437 → 0.505 ms | 0.437 → 0.503 ms | 1,824,096 → 1,764,096 |

The short marker-at-start replacement is slower in this sample. The numbers
are synthetic cumulative allocation, not retained memory, and do not establish
whole-application speedup. The byte search still has a worst case proportional
to text length times marker length. No CI, live terminal or Keeper delivery
result is asserted here.

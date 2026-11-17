# Reuse the count and lazy digest index in Librarian selection

Parent helper commit: `8ae76062efffdccbe269c2f3247465cce141c842`.
Behavioral baseline: `ea0b8d1fd284fad784557373fd82e8565a774b10`.
The production change replaces separate `annotate` and `atom_opening_digest`
construction in `Range.select` and `Range.unread_turns` with the fixed
`atom_opening_index` tuple. The public Range MLI is unchanged. The complete
sources/signatures and hashes are bound in [results.json](results.json).

Every cut lookup, cursor lookup, restart/settlement branch and error occurs
in the same order. Already-read cuts are still checked. No early filter,
prehash, memo, global cache, changed read policy or progress write is added.
The new regression explicitly preserves a writer error in an already-read
non-finite ToolUse opener while the newer cursor opener is valid.

Focused native validation used OCaml 5.5.2 and existing dependencies:

- Complete actual Window and Range ML/MLI compile with fatal warnings
  4/8/32/69 in fresh output directories, including the changed Window CMI.
- 105 synthetic cases make 630 before/after comparisons of actual Range
  select(all), select(first) and unread results/errors and ordered digest
  lookup indices. Cases cover empty/history/caught-up/mismatched/other-trace
  cursors, truncation, restart, torn/malformed boundaries, continued-start
  settlement and lazy non-finite writer errors. Result comparison uses
  `Marshal.No_sharing` on the unchanged pure selection representation;
  observer ports record only indices around real digest calls.
- Actual existing Range test source executes 30 baseline and 31 candidate
  cases through an Alcotest runner scheduling port. Only warning 4 is
  suppressed inside these extracted test modules (`[@@@warning "-4"]`).
  The exact added regression also compiles and runs outside suppression,
  with all four production warnings fatal. This is not a repository suite
  or CI verdict.

The modules compile from complete source as isolated nested modules. Other
project dependencies come from the recorded existing archives, whose exact-head
build provenance is not established. No complete corrupt-store fixture or
actual Librarian/runtime workload was executed. No Dune, full product build,
CI, server read, provider call, installation or runtime GC was performed.

The [helper layer's construction-only measurements](../atom-opening-index-20261117/README.md)
show the allocation/CPU effect of removing duplicate labelling, including
lookup-only tradeoffs. This consumer fixture takes no new timing measurement
and establishes no share of total process CPU, RSS or runtime latency.

Replay with existing compatible dependencies into a new directory:

```sh
python3 docs/evidence/librarian-range-atom-index-20261117/range_replay.py \
  --repo "$PWD" --base ea0b8d1fd284fad784557373fd82e8565a774b10 \
  --opam-prefix "$OPAM_PREFIX" --build-root "$EXISTING_BUILD_ROOT" \
  --typing-prefix "$EXISTING_TYPING_PREFIX_JSON" \
  --out "$PWD/artifacts/librarian-range-atom-index-replay"
```

The typing prefix is an existing compiler-prefix JSON array with compatible
includes, `-open Masc`, and fatal warnings 4/8/32/69. The helper replaces its
compiler/output path and never builds missing dependencies. The retained
receipt includes the exact helper/regression/source hashes and original raw
receipt hash; archive paths are relative to the supplied build root.

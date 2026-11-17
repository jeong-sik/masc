# One atom labelling for count and lazy opening digests

Base: `ea0b8d1fd284fad784557373fd82e8565a774b10`.
`atom_opening_index` returns the actual `annotate` count and the existing lazy
opening-digest closure. A private builder shares opener construction with the
lookup-only API. Both APIs keep the same bytes, bounds and lookup-time errors;
neither prehashes or memoizes. There is no new cache or policy setting.

The consumer layer can replace a separate `annotate` plus
`atom_opening_digest` construction. This layer adds the helper without changing
Range selection, cut filtering, cursor matching or checkpoint validation.

The source-bound native fixture compares complete baseline/candidate Window
ML/MLI modules against existing dependencies, and records their hashes in
[results.json](results.json). OCaml 5.5.2, macOS arm64:

- 4,883 comparisons across 126 fixed/deterministic histories cover count,
  all opening digests, out-of-range indices, mixed roles/origins, pinned and
  historical context, orphan/attached tools and non-finite lazy writer errors.
- Actual existing focused test source executed 37 baseline and 38 candidate
  cases through an Alcotest runner scheduling port. Existing warning 4 is
  suppressed only inside those extracted test modules (`[@@@warning "-4"]`).
  This is not a passing repository test-suite claim.
- Actual complete production ML and public MLI compile with `ocamlopt` and fatal
  warnings 4/8/32/69 against existing CMIs. The exact added regression also
  compiles and executes outside the test-module warning suppression with all
  four warnings fatal. Full test-file typing fails on existing fragile matches
  in both baseline and candidate; no unrelated tests were rewritten.

Six alternating AB/BA rounds measure construction without digest lookup.
Bytes are median allocations per operation; ratios are medians of paired CPU
times. The source history is preconstructed and identical. Full-major GCs run
only in the disposable fixture. The host load is uncontrolled.

| Messages | Count+lookup before B/op | After B/op | CPU ratio | Lookup-only CPU ratio |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 80 | 80 | 0.822 | 1.005 |
| 1 | 296 | 200 | 0.753 | 1.133 |
| 100 | 25,592 | 14,984 | 0.631 | 1.003 |
| 10,000 | 2,560,193 | 1,493,569 | 0.463 | 1.031 |

Lookup-only allocations remain exactly equal at every measured length. Its
one-message construction is a few nanoseconds slower in this fixture; no
unconditional timing improvement is claimed. A prior tuple-wrapper prototype
added 24 bytes per lookup-only construction and was replaced by the private
builder. These are construction-only results, not whole-call hashing costs,
process CPU share, held heap, RSS, latency or installed-runtime evidence.

The helpers compile complete source and link six recorded existing project
archives. Their exact-head build provenance is not established. No Dune, full
product build/link, CI, runtime read, provider call or installation was used.

Replay into a new directory, with existing compatible OCaml 5.5.2 artifacts:

```sh
python3 docs/evidence/atom-opening-index-20261117/replay.py \
  --repo "$PWD" --base ea0b8d1fd284fad784557373fd82e8565a774b10 \
  --opam-prefix "$OPAM_PREFIX" --build-root "$EXISTING_BUILD_ROOT" \
  --typing-prefix "$EXISTING_TYPING_PREFIX_JSON" \
  --out "$PWD/artifacts/atom-opening-index-replay"
```

The typing prefix is a JSON array of an existing compiler invocation prefix,
including compatible dependency includes, `-open Masc`, and fatal warnings
4/8/32/69. The helper replaces its compiler/output include path. Missing or
incompatible dependencies are reported; it never builds the project. The
retained result is the raw receipt plus derived medians, with its original
receipt hash. Project archive paths are relative to the supplied build root.

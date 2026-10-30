# Keeper host-memory projection conflicts

Baseline: `cfe7f4e071f1e4e2aee3161760a3216d17bf0c3e`.
Candidate source and tests: `2a2a301924f71e79e822c9de942365b1084d4c72`
(module blob `95d35152009a080c63c959720f8f4463eb0fc777`, interface blob
`e5bd10a79aafa4b035c2bedf77b93efff90e0f1f`, test blob
`95074690bee7fd6caf277b02c2235036fdbac0f4`).

Validation and durable proposal retention can yield. If another call replaces
the prepared projection while one is in progress, the older callback could
previously overwrite the newer projection or render a projection it had not
validated. The candidate retains one immutable pair in an atomic cell and
checks the observed identity. A stale capacity reduction returns an error
instead of authorizing its retry; a conflict detected during revalidation
returns an explicit unavailable message with no selected records. A proposal
already durably recorded may remain in the journal and is not a delivery
receipt. The capacity caller may therefore return the original overflow rather
than retrying when a conflict is detected.

These checks protect the cell at the point of observation and commit. They do
not bind a returned string to a later provider dispatch, serialize arbitrary
validation or retention callbacks, or prove that the underlying source cannot
change after revalidation. No real overlapping Keeper call, provider request,
or transmission resulting from such an overlap was observed.

## Reproduction and scope

On arm64 macOS 26.6.1, OCaml 5.5.1 `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) compiles the exact projection functions
extracted from each revision and four cases extracted from the repository test.
The baseline passes the prior failed-revalidation case and fails all three new
controlled-reentry cases; the candidate passes all four. The separately saved
baseline failure outputs are
[`capacity`](baseline-capacity-failure.txt),
[`validation`](baseline-validation-failure.txt), and
[`receipt`](baseline-receipt-failure.txt). In the second case, the baseline
fails on the first of two validation outcomes, so its later branch is not
claimed as observed.

```sh
python3 docs/evidence/keeper-memory-projection-conflict-20261030/reproduce.py \
  --baseline cfe7f4e071f1e4e2aee3161760a3216d17bf0c3e \
  --candidate 2a2a301924f71e79e822c9de942365b1084d4c72 \
  --out artifacts/keeper-memory-projection-conflict-20261030/reproduction
```

The reproduction uses real Yojson and unchanged `String_util` sources. Prompt
rendering, error types, result syntax and test path are shims; it does not
compile the whole module, interface, real prompt template or provider. The
[`harness`](harness.ml.txt) additionally compares output and callback records
across 15,000 seeded sequential operations. It uses two OCaml domains with a
condition-variable gate to hold one capacity receipt while the other domain
publishes a source-revalidation failure. In this controlled overlap the
baseline returns `Reprojected` for the stale reduction; the candidate returns
an error and retains the newer unavailable projection. The next render also
revalidates, so this observation alone does not establish an actual data leak.

## Captured measurements

[`samples.csv`](samples.csv) retains seven alternating-order samples of
500,000 already-valid synthetic reads, with a no-I/O validator and shim
renderer. Median CPU was 1.211 → 1.173 ms, wall 1.211 → 1.172 ms, and
allocation 96 → 96 bytes. These short samples exclude contention, changes,
real rendering, receipt I/O and the Keeper turn; they do not establish an
application speedup. No Dune build, CI result or live Keeper behavior is
asserted here.

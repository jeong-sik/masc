# Keeper host-memory projection state

Baseline: `0fb41571570430d9937ee499fc244c22483f6fd5`.
Candidate source and tests: `c3817eb787d713be9408cd574a2e62ee793ea7c8`
(projection module blob `65dad0c031414cc6d8a1d50c88e73179a98b3e9e`, test blob
`eeb77d476efa7748cbaec75fa1a6eccd770b6358`).

The prepared host-memory projection previously held its JSON payload and
cached rendered text in separate mutable fields. It now holds the two in one
immutable projection behind one mutable cell. Capacity reductions are still
retained before publication and source revalidation still precedes reuse.
The projection receipt is a proposed provider-bound projection, not proof of
transmission. The update is not synchronization across yielding validation or
retention callbacks: concurrent or reentrant updates can still invalidate an
earlier decision and are not resolved here.

In the revalidation-failure path, rendering now completes before the new pair
is assigned. If that rendering raises, the old complete pair remains and a
later call revalidates it. Previously the payload assignment preceded rendering,
so an exception at that point could leave the new payload paired with the old
text. The injected failure below demonstrates that path under a shim; no
production rendering exception has been observed or claimed.

## Reproduction and scope

On arm64 macOS 26.6.1, OCaml 5.5.1 `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) compiles the exact projection functions
extracted from the old and new module and the new repository regression test.
The test passed against both versions: a revalidation failure followed by a
failed receipt yields an unavailable projection, and the next validation sees
that same unavailable payload. The real Yojson and unchanged `String_util`
sources are used. The prompt registry, error type, result syntax and test path
are explicit shims; the full module, runtime and actual prompt template are
not compiled in this reproduction.

```sh
python3 docs/evidence/keeper-memory-projection-state-20261030/reproduce.py \
  --baseline 0fb41571570430d9937ee499fc244c22483f6fd5 \
  --candidate c3817eb787d713be9408cd574a2e62ee793ea7c8 \
  --out artifacts/keeper-memory-projection-state-20261030/reproduction
```

The [`harness`](harness.ml.txt) compared 15,000 seeded normal render and
capacity-reduction operations, including validation and receipt failures,
and checked both outputs and callback records. It then injects an exception
in the shimmed renderer after successful retention: the baseline's next call
validates an unavailable payload but returns the old selected text; the
candidate's next call validates the still-matching original payload and text.
The successful retention in this synthetic case represents a proposal, not a
delivered request. This does not establish that the real renderer throws at
that point, nor prove safety against overlapping callbacks.

## Captured measurements

[`samples.csv`](samples.csv) contains seven alternating-order samples of
500,000 already-valid synthetic render calls, with a no-I/O validator and the
shim renderer used only during preparation. Median CPU was 1.113 → 1.120 ms,
wall 1.111 → 1.119 ms, and allocation 96 → 96 bytes. These short samples do
not cover projection changes, retained memory, actual prompt rendering, I/O,
or a Keeper turn and do not establish an application performance improvement.
No Dune build, CI result or live Keeper delivery is asserted.

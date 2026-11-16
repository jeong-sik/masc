# Recheck verified predecessor bytes without restoring the history again

Source base: `e0e819e29968366c1dffb59ad625ba4e17d4ac22`, 2026-11-16.

The live investigation found one connected chain of 23 retained history
requests with identical source and basis digests. Its 22 predecessor links
bound the captured parent digests. Body sizes totalled 1,413,643,699 logical
bytes. This is retained file data, not an RSS measurement, and not all nodes
were created by the observed process. Matching progress cursors alone does
not rule out a Memory commit awaiting progress settlement.

The host fully restores every predecessor while authorizing a request and
again in each dispatch guard. The body reader parses nested source JSON,
reconstructs frozen prompts and serializes canonical values. Fenced ancestors
need the same immutable request on recheck, while their fences, records and
acknowledged child intents must still be read freshly.

The candidate verifies each predecessor completely at authorization, then
keeps only its immutable identity/binding/summary and validated index. It
retains neither the ancestor request nor its progress, which can itself
contain a full child request. Each guard still reads the actual record and
body together through the existing owned-store serializer and hashes the
complete bytes. Different or absent bytes refuse. Equal SHA-256 bytes reuse
the already validated canonical decode. Physical source roots, lineage,
fences, intent acknowledgements and cycles are checked again. A known-basis
link still restores requests to compare the full current publication intent.
The proof is private and bound to the same store and original request objects;
there is no cross-request/global cache or persisted format change.

## Focused source-extracted probe

```sh
python3 docs/evidence/librarian-predecessor-proof-20261116/probe.py \
  --source-root . --output artifacts/predecessor-proof-replay
```

Requires the project's OCaml 5.5.2 toolchain, `ocamlfind`, Yojson and Digestif C
backend. The probe extracts the candidate owner load/recheck functions, JSON
canonicalizer and SHA-256 implementation. All request data is synthetic.

Nine checks passed: unchanged bytes; same-length corruption; missing body;
changed summary, digest or binding; missing record; fresh progress; and a weak
reference check that the proof retains neither original JSON nor a child
request embedded in progress.

For one 61,462,026-byte synthetic canonical body, the measured owner load cost
was 0.519 s CPU and 380,278,384 allocated bytes. Its verified-byte recheck
cost 0.174 s CPU and 61,672,216 allocated bytes. These are individual helper
measurements on a loaded host, not process CPU/RSS, a full-chain benchmark or
a predicted runtime speedup. Source digest and exact output: [results.json](results.json).

The probe supplies filesystem/progress ports: it does not exercise owned
descriptor, sync or serializer checks. Those production store operations are
unchanged. Nested History restoration, full lineage and provider behavior are
outside the benchmark.

## Typing and integration limits

[typing.json](typing.json) records fatal-warning checks with OCaml 5.5.2:

- Candidate Owner interface and implementation typed directly.
- Complete source-extracted Lineage implementation/interface typed as a functor
  over the extended Owner API, with original retained/record/error type equalities.
  No substitute implementation was linked or executed.
- Candidate Lineage interface and server authorization implementation typed
  against the prebuilt dependencies.

Directly combining the new Owner interface with stale prebuilt dependent CMIs
fails their interface checksum checks. This is not a full project typecheck or
link. No Dune build was run.

The existing durable-history integration scenario adds actual dispatch-guard
checks for unchanged, missing and same-length-corrupted ancestor bodies,
changed summary, proof substitution and no provider/cursor effects. It was
parsed but not executed. Full regression and installed-runtime recovery remain
unverified. This patch does not stop automatic continuation creation or fix
worker allocation; the separate oversized-worker request repair is PR #52504.

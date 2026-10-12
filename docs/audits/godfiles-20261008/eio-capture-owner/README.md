# Eio foreground capture ownership, 2026-10-09

Parent: `459cb14f448bb462f5fa8d807d71b78d42d803a9` (#42003).
Tracking issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Process_eio` combined runtime acquisition, caller error/timeout policy, Unix
fallback, pipe draining and Eio child cleanup. Ordinary and streaming two-stream
execution duplicated the same pipe/spawn/drain/await/finalize sequence, differing
only in callbacks. The pipeline carried another copy of the EOF drainer.

`Eio_process_capture` now owns foreground pipe capture and Eio cleanup effects.
Its dependencies are explicit: switch, manager, clock, cwd, buffers and callbacks.
It neither reads global runtime initialization nor decides caller timeout/error
results. Runtime lookup, fallback decisions, refusal classification and redirect/
pipeline orchestration remain in `Process_eio`. The public execution API is intact;
the existing public grace value binds directly to the owner.

Ordinary and streaming commands now call one two-stream implementation with
optional callbacks. The stdin caller no longer branches on callback presence.
The owner also supplies the drainer to file redirects and pipeline consumers.
Raw capture append, callback, preview append, EOF receipt, reader close and await
retain their order. Each stream retains one producer. Held-open stdin remains a
separate protocol primitive; cleanup closes it first. TERM grace, cancellation
propagation and switch-owned final reap retain their existing behavior.

The public grace documentation incorrectly claimed redirected outputs receive no
cancel grace, and that early EOF ends the grace. Current code grants the full
existing grace in both cases. The interface now documents that behavior; moved
comments refer to the actual foreground manager rather than the previous Eio
backend implementation. No grace duration, timeout or retention ceiling changed.

## Direct consumers and verification

| Boundary | Actual scenario | Result |
| --- | --- | --- |
| Stdout and shared two-stream capture | Cancellation propagation, ordinary stderr, streaming callbacks, callback exception/cancellation, multiple chunks | Existing coverage cases passed |
| Bounded preview | Existing oversized/small child output assertions now execute on both Unix fallback and initialized Eio; small output is checked byte-for-byte | Two strengthened cases passed |
| Shared pipeline drainer | Two real stages emit multiple stdout chunks and stderr; both callback modes preserve final stdout, stage-ordered stderr and nonzero status; callback stderr preserves every byte irrespective of concurrent arrival order | New capture-owner case passed |
| Cleanup owner | Early EOF, file redirects, TERM handler, ignored TERM, grandchild-held stdout, parent cancellation during reap | Four cancellation-grace and three timeout-grace cases passed |
| File redirect consumer | Actual stdout file, truncate/append, independent streams, stdin file and unopenable target | Six existing cases passed |
| Raw capture EOF and publication consumer | Real child output retained until release, stale EOF refused, captured secret snapshot, binary/partial UTF-8 bytes, lane output ceilings | Seven existing cases passed |

[checks.json](checks.json) records the final three-target focused build and terminal
results. Thirty selected coverage cases, six redirect cases and seven publication
cases passed: 43 unique scenarios. Skipped cases are not counted. These tests use
isolated local child processes and temporary paths. No live Keeper lane, provider,
operation or deployment was touched. Full CI/suites and Linux execution are not
claimed.

The coverage binary was rebuilt after the final normal-pipeline callback assertion
was strengthened. Redirect/publication production and test inputs, and their
executables, were unchanged during that test-only enhancement; the final build
includes all three targets. Earlier builds and 29-case/one-case runs are labeled
intermediate receipts, not substituted for current coverage evidence. Stored logs
normalize trailing whitespace.

[extraction-comparison.json](extraction-comparison.json) records eleven bounded
helper comparisons against the parent. Comment/whitespace normalization is explicit;
two-stream callback generalization and held-open callback defaults are named
transformations. This supports extraction review, not behavior or independent
approval. Pipeline drainer replacement and caller simplification additionally
require reading the complete diff and the actual tests above.

## Remaining campaign scope

`process_eio.ml` shrinks from 2,054 to 1,610 lines; the effect owner has 357 lines
plus a 66-line interface. This removes duplicate logic as well as separating
responsibilities. Falling below 2,000 lines does not complete the original
candidate: runtime acquisition, Unix capture, timeout/refusal policy, redirect
acquisition and pipeline orchestration remain pending full semantic assessment.
All original 171 candidates remain in scope; 17 production candidates are partial
and 58 production candidates still require semantic review.

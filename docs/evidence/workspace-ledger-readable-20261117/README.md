# Ledger readability without briefing observation

The workspace inventory HTTP route uses `Ledger.observe` only to distinguish an
unavailable ledger from a missing/readable one. That observation also canonically
encodes and hashes the ledger, resolves the briefing prompt, loads the briefing,
checks its sources and counts classifications. This happens before cache lookup.
The consumer layer replaces it with a strict fresh readability check on a CPU
worker; the existing cache key, TTL and inventory producer remain unchanged.

Baseline: `d774939f03a5777f28c5ca8b3e1e01acdbe54cca`. Complete baseline/candidate
file digests and capture hashes are in [provenance.json](provenance.json).
`check_readable` shares the existing lstat/read/strict-decode implementation with
`observe`. It does not accept symlinks or corrupt ledgers, retain a snapshot, or
authorize writes. Missing ledgers succeed only in an existing workspace.
`observe` retains its complete projection and exception behavior.

## Native observations

OCaml 5.5.2, 64-bit macOS, fatal warnings 4/8/32/69. The complete actual old/new
ML and MLI were compiled against compatible prebuilt dependencies. The fixture
adds only `open Masc` and named aliases; it uses actual ledger and briefing
implementations and owned temporary files. No substitute decoder/store is used.

[observed.json](observed.json) retains 46 assertions: equivalent availability
and exact errors, independently expected availability and unchanged full
`observe` results. Cases include absence, valid replacement, malformed JSON,
invalid references/schema, corrupt briefing, valid-byte/dangling symlinks,
directory, FIFO refusal and missing workspace. Permission denial, concurrent
replacement races and Eio cancellation were source reviewed, not executed.

The complete maintained ledger suite also passed all 19 cases. Its only runtime
adaptations are the Ledger namespace and an owned prompt/environment prelude.
Existing fragile matches were made exhaustive without changing the test oracle.
These are standalone native checks, not a Dune or full product build.
The independent [source review](source-review.json) binds the three source
hashes; it predates the terminal maintained-suite receipt. The consumer layer's
review additionally checks that receipt and the final worker selection.

The fixture alternates old/new order for four rounds of eight checks, with a
real saved ledger and saved briefing preparation. For 16 synthetic claims of
16 KiB each, the ledger is 321,777 bytes and briefing 320,864 bytes:

| Metric, eight checks | Full observation gate | Readability gate |
| --- | ---: | ---: |
| Current-domain allocation-counter bytes | 45,359,456 | 10,652,832 |
| CPU seconds, round 1 | 0.096353 | 0.023471 |
| CPU seconds, round 2 | 0.102966 | 0.023383 |
| CPU seconds, round 3 | 0.100243 | 0.023165 |
| CPU seconds, round 4 | 0.094331 | 0.023390 |

The median of paired CPU ratios is 0.23734; allocation-counter ratio is 0.23485.
The smaller four-claim case has ratios 0.24446 and 0.26255 respectively.
`Gc.allocated_bytes` uses current-domain counters; measurements include native
counter precision and measurement overhead. `Sys.time` is process CPU in a
standalone process without Eio workers. Wall time uses `Unix.gettimeofday` and
does not prove monotonic timing. GC runs only in the disposable fixture.

These results cover the preflight gate. They do not establish HTTP/cache-hit/304
latency, pool dispatch execution, server CPU fractions, RSS recovery or leak
resolution. No real runtime data, provider, restart or installation was used.

## Replay

```sh
python3 docs/evidence/workspace-ledger-readable-20261117/replay.py \
  --repo "$CANDIDATE_CHECKOUT" --build-repo "$COMPATIBLE_BUILD_CHECKOUT" \
  --opam-prefix "$OCAML_552_PREFIX" \
  --out "$OUTPUT_REPO/artifacts/workspace-ledger-replay-new"
```

Output must be a new directory under `artifacts`. The script verifies source and
fixture hashes, compiles the complete modules, then runs the actual fixture and
maintained suite in owned temporary roots. With `--consumer`, it additionally
compiles the complete HTTP interface/implementation from the supplied checkout;
it records those source hashes but does not execute the route.

[native-recipes.json](native-recipes.json) is a path-normalized derivative of
the captured argument vectors with previous experiment include directories
removed. It needs the compatible prebuilt `_build` tree and installed packages;
missing/incompatible artifacts fail visibly. This is not a clean-build recipe.
Original command-receipt digests are retained in provenance; retained fixture
and observation bytes are unchanged. Any replay writes new receipts/results
and does not replace these observations. The curated recipe replay is recorded
in [replay-verification.json](replay-verification.json).
That successful replay has ten terminal commands, 46 assertions and 19 tests;
its separate results are [replay-observed.json](replay-observed.json). The first
curated replay refused a temporary fixture directory under HOME before running
source cases. The corrected script uses the system temporary directory without
bypassing the isolation guard; the failed run's digests remain in the receipt.

## Declared dependency correction

The original broad native include paths did not verify Dune dependency
declarations. CI type-check run `44015974590`, job `133813948816`, on upper
head `76713ba09c39add7b9f5f68fa56e1d6908333d42` failed at the new `Unix`
calls because the test stanza did not declare `unix`. The stanza now declares
it directly; the test body and production files are unchanged.

[dependency-visibility-verification.json](dependency-visibility-verification.json)
records a second focused check. Only the frozen test's declared libraries and
the fresh candidate alias are directly visible; other dependency directories
use OCaml's `-H` hidden includes. The actual maintained suite fails with
`Unbound module Unix` when Unix is hidden, compiles when it is declared, and
passes all 19 cases. An empty test interface also checks for unused helpers.
This remains a compatible-prebuilt native check, not a local Dune build.

```sh
python3 docs/evidence/workspace-ledger-readable-20261117/check-declared-dependencies.py \
  --repo "$CANDIDATE_CHECKOUT" --build-repo "$COMPATIBLE_BUILD_CHECKOUT" \
  --opam-prefix "$OCAML_552_PREFIX" \
  --out "$OUTPUT_REPO/artifacts/workspace-ledger-declared-deps-new"
```

The checker verifies the frozen source and Dune-file hashes in
[dependency-visibility.json](dependency-visibility.json). Its seven commands
include one expected hidden-Unix failure. Original captures, recipes and
provenance remain unchanged; this additional check covers the declaration gap.

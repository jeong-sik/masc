# TUI chat-history CPU decoding

The aggregate history, memory-journal and older-page readers in
`bin/masc_tui_http.ml` performed JSON parsing and typed row folding directly in
their calling fiber. These successful response bodies now use the existing
`Masc_tui_response_decode.run` boundary, as other TUI JSON readers already do.
HTTP, credentials, refusals, cache updates and dataset admission remain with
their existing callers. Only immutable response text and pure decoding enter
the worker. The public types, errors, canonical page size and cursor rules do
not change.

## Observed live request sizes

On 2026-10-20 UTC, concurrent HTTP reads for code-reviewer returned:

| Observation | Aggregate history | Memory journal |
|---|---:|---:|
| 1 | 1496.20 ms / 1,068,393 bytes | 37.07 ms / 27,747 bytes |
| 2 | 80.93 ms / 1,068,393 bytes | 10.16 ms / 27,747 bytes |
| 3 | 120.00 ms / 1,068,393 bytes | 44.85 ms / 27,747 bytes |

These are endpoint observations under differing cache state, not TUI paint,
CPU decode times or before/after measurements. The current TUI still performs
aggregate history followed by memory-journal reading before delivering the
combined result. Independent source delivery and earlier canonical-page
display remain separate follow-up work in #44249.

## Focused source experiment

```sh
python3 docs/evidence/2026-10-20-tui-history-decode/reader_probe.py \
  --before 8c2b56cb19a9f44397aa876a81396ad872ba5ec0
```

Requires OCaml 5.5, ocamlfind, eio_main and yojson. It compiles only a standalone
temporary probe, without Dune or a MASC build.

The script extracts the actual three reader bodies before and after the
change, plus the actual response-decode wrapper. JSON parsing, domains and
Eio.Executor_pool are real. HTTP, typed row projections, named-switch tracing
and the MASC pool adapter are fixtures. It therefore verifies the new boundary
and result/error routing, not native MASC linkage, complete row decoding or the
production pool's cancellation/cleanup policy.

Observed output:

```text
equivalence_cases=42 worker_projections=9 caller_progress_while_worker_waits=PASS exception_no_replay=PASS
```

The cases include successful JSON, typed fixture rejection, malformed JSON,
stale 409 pages, HTTP refusal and transport failure, with and without a pool.
HTTP/refusal callbacks stay on the caller. Successful typed decoding executes
on the worker; a caller fiber progresses while an actual extracted reader's
projection waits, and projection exceptions are not replayed.

Existing native fixtures in `test/test_tui_server_identity_refresh.ml` cover
the shared response-decode boundary's worker routing, caller-owned cache,
navigation admission, nested errors and inline fallback. They were read, not
run for this change. Existing history decoder fixtures remain relevant to row
and cursor semantics; this change adds no new decoder semantics or API.

The changed ML file passes syntax parsing and `git diff --check` passes. No
local Dune build, native MASC test execution, full CI, installed new TUI binary
or TUI paint/keyboard latency improvement is claimed.

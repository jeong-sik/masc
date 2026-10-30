# Exact query identity for cached observability reads

## Reproduced installed behavior

Authenticated, read-only requests against installed server
`568fd12715f0cceee7325793f5d211d19e9730c5` in one unchanged runtime:

| Requested file-change window | Returned window | Status | Wall time ms |
| --- | --- | --- | ---: |
| 1.01 hours | 1.01 hours | 200 | 521.22 |
| 1.04 hours | **1.01 hours** | 200 | 0.89 |
| 1.01 hours | 1.01 hours | 200 | 0.78 |

The second answer is a wrong cache hit. Its low latency is not an optimization.
This sample proves one incorrect answer among these three requests; it does not
estimate the fleet's error rate. `live-baseline.json` retains the measurements
without publishing the Keeper's private log rows or credentials.

## Repairs

Four HTTP cache boundaries rounded effective floating-point parameters or
concatenated unescaped fields:

| Surface | Previous lossy identity | Distinct effective inputs |
| --- | --- | --- |
| Keeper file-changes | window with one fractional digit | 1.01 / 1.04 hours |
| IDE file-activity | window with one fractional digit | 1.01 / 1.04 hours |
| Tool quality | window with two fractional digits | 1.001 / 1.004 hours |
| Telemetry | second bounds with three fractional digits | 1000.01 / 1000.04 milliseconds |

Telemetry additionally collapsed an absent session filter and an empty filter.
Its raw delimiters also collided for `(session="a:o=b", operation="c")` and
`(session="a", operation="b:o=c")`. The reader compares these filters exactly,
so their query results and echoed queries are distinct. Raw source spellings
could resolve to the same source set while still requiring distinct query echoes.

Keys now serialize explicit JSON tuples. Effective floats use unrounded `%h`
strings; the representation is the standard library's hexadecimal float format
([OCaml 5.5 Printf](https://ocaml.org/manual/5.5/api/Printf.html)). Equivalent
parsed numeric spellings still produce the same component. Keeper keys retain
committed revisions and workspace roots. IDE keys additionally include the
request's base path; tool-quality keys use the existing workspace partition.

Telemetry reuses the same query object inserted into the response, plus exact
float witnesses for both bounds. This preserves raw source, optional filter
presence, empty strings, whitespace and field boundaries without duplicating a
second interpretation of the query. The trimming query-key helper is not used:
trimming an exactly matched filter would introduce another collision.

Parsers, clamping, query semantics, TTLs, permissions and response schemas are
unchanged. This is a correctness repair; no installed speedup is claimed.

## Focused validation

Baseline source: `376e0f1abdd03163f7af4b4791c24ad46dd043f0`.
Two explicit native targets only, using OCaml 5.5.1:

- `test/test_dashboard_http_core.exe`
- `test/test_server_ide_http.exe`

Actual HTTP requests pass through the router, response cache and serialized
response, not a substitute key implementation. The original handlers fail six
new cases: Keeper window, IDE window, quality window, telemetry bound, telemetry
optional/delimited filter, and telemetry raw source echo. After repair all six
pass. The Keeper test also puts a real retained row between the two requested
window floors: the narrower window returns zero rows, the wider window one.

Final focused selection: **18 passed** (five Dashboard query cases, nine IDE
query/auth cases, three existing key/partition cases and one existing prepared
response case). The Keeper alias test requires a present ETag, a matching
validator for 1.01/1.010 and exactly two payload preparations for
1.01 → 1.04 → 1.010. The hook fires after real cache serialization; this directly
checks reuse rather than inferring it from ETag equality alone.

Telemetry's one-second TTL may legitimately expire during a slow test run, so
its tests assert request/response correctness and make no preparation-count or
same-validator promise across its reads. Both since and until bounds, omitted
and empty filters, whitespace, delimiter-containing values and raw source
aliases are exercised. New cross-workspace behavior is source-reviewed; no
additional black-box workspace-switch scenario is claimed.

`validation.json` binds final source hashes, explicit commands, result counts
and retained log hashes. Full regression and full CI were not run; the latest
full-regression run identity was not inspected. This candidate is not installed.
Independent source reviews are separate from GitHub approval and deployment.

## Related audit and remaining work

- #45594 and Native Stack #45551's #45596 overlap on Candle replay-clock
  identity. #45595 already handles duplicate execution observation reads.
  This change does not duplicate or combine those implementations.
- Tool-call index and physical chat stamps already exclude access time. Their
  modification/identity checks remain authoritative; do not remove those checks
  merely because a live query is slow.
- Namespace hash excludes generated envelope times. SSE publication/order
  metadata has consumer semantics and cannot be discarded wholesale.
- Repeated approval-queue read failure fabricates a new observation timestamp
  in runtime-trust causal data. This is a separate candidate requiring a clear
  distinction between observation time and durable event time. The earlier
  37-Keeper frozen input contained zero such failures, so no current latency
  cause or improvement is attributed to that path.
- A positive-window tool-quality read ignores `n`, while its key still includes
  it. This is a separate reuse opportunity. Its current parser allows NaN to
  select Recent mode, where `n` is material; excluding `n` just because the
  optional window exists would introduce a new wrong-hit bug. Leave the input
  in this repair and verify both modes before a later optimization.

Remaining operational verification is installation of a reviewed candidate and
repetition of the same public requests. Source/native success does not certify
installed behavior, visible Dashboard loading or the wider performance goal.

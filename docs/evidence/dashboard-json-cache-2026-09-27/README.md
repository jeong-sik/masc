# Avoid unused HTTP encoding in JSON-only dashboard cache fills

## Observed path and source change

A five-cycle diagnostic on the verified isolated baseline server
`8c23cd524c28048a0f3a859fb86f4e001428c9a9` (artifact `10907429339`,
[build 36246971815](https://github.com/jeong-sik/masc/actions/runs/36246971815))
used 250 synthetic tasks and existing DEBUG phase logs. Its ten GET windows
contained one render line for each first response and none for warm responses.
Rounded total render times were 4/8/7/4/8ms, data load 1–2ms and assembly 2ms;
`cache_compute` reported 8.719/11.782/11.169/7.877/11.807ms. Every owned server
was reaped with exit zero. The only model request was a local model-list GET.

These DEBUG observations include instrumentation and scheduling effects. The
log rounds to whole milliseconds and omits operations; a printed zero is not
zero cost, and subtracting phase totals cannot attribute the residual to a
specific operation. This is diagnosis, not a before/after benchmark.

Source inspection then found that both JSON-returning cache APIs call payload
APIs which eagerly run `Yojson.Safe.to_string` and compute an ETag on every
fill. Internal callers use only the AST. Execution's first-response path later
serializes the separately decorated response for HTTP as well. The diagnostic
does not isolate the cost of that redundant encoding; the source establishes
that the JSON-only fills perform it.

The change retains an AST-only internal value for JSON callers. HTTP-first
fills still prepare immutable bytes/ETag/codecs on their existing worker before
publication. A later HTTP reader of an AST-only key prepares identity bytes
without rerunning the producer. Eio readers coalesce through Eio.Lazy; a native
thread avoids Eio effects and may encode concurrently, with every successful
reader adopting the same atomic winner. The existing per-key preparation policy
is unchanged: JSON-first producers use identity-only preparation.

Preparation claims the lazy inside the worker, avoiding a single-worker queue
cycle. Timeout wraps that worker call; the lazy restarts when its forcing
fiber is cancelled. A caller timeout does not prove that an admitted worker
stopped immediately. Only a successful caller publishes prepared bytes, and detached old values
cannot republish a globally invalidated entry. Existing table tokens, expiry,
SWR scheduling, prepared HTTP fills, seeds and timeout envelopes remain.

`peek_payload` now reports already-prepared bytes only; AST-only entries have
`peek` data but no payload until preparation succeeds. It never serializes or
waits. Ordinary serialization exceptions remain memoized by the lazy for that
value; cancellation is retryable.

## Verification scope

Added scenarios cover no serialization on JSON fills/hits, shared concurrent
materialization, JSON reads during materialization, invalidation during a paused
preparation, nested reads with a single occupied worker, timeout/cancellation
with and without a worker pool, and concurrent native-domain reads after a
default Eio clock is installed. Existing HTTP preparation, seed, stale-value,
replacement-token and timeout coverage remains.

OCaml syntax parsing and whitespace checks ran locally. Source-head PR CI passed
all five gates and its selected tests, including all 58 Dashboard_cache cases.
The [isolated native comparison](comparison/README.md) retains a separate
24-session before/after measurement. It shows lower aggregate first-response
medians with mixed tails and mutation/warm results; no general speedup, allocation
measurement, production deployment or 0.1ms achievement is claimed.

## Diagnostic receipts

This directory retains the exact diagnostic runner, runtime fixture, startup
identity with host paths redacted, ten observations, selected phase lines with original log byte offsets,
and cleanup. The original full DEBUG log and window captures remain local;
their hash/offset checks were verified by root and two independent reviewers.
Raw server logs are not published. Retained selected lines do not independently
reconstruct that original log. No operator runtime data or credentials were used.
The separately retained ordinary-level paired measurements for #39325 are not
pooled with this diagnostic or attributed to this new source change.

The PR review request to remove host-specific paths is addressed in identity
and diagnostic-summary; comparison/redaction.json records original and published
hashes. Numeric observations and source/binary identities are unchanged.

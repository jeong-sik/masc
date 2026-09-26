# Reuse prepared bytes on the first default execution response

## Motivation

A read-only loopback observation made 80 sequential execution GETs, alternating
public/authenticated requests and identity/gzip acceptance. Every response was
valid HTTP 200; server identity was unchanged across this one observation.
The first public request took 130.32975ms (`cache_compute` 125.578ms); the first
authenticated request took 100.402209ms. Aggregate observations and exact
runtime identity are in `observations.json`. Normal runtime work was active.
No server restart/deployment was performed. These numbers are not a controlled
before/after comparison and do not measure the cost of duplicate serialization.

## Source finding and change

On the non-forced, unparameterized execution fallback, the handler selected a
successful snapshot, prepared its identity/compressed bytes in the CPU worker,
then discarded those bytes and returned `Execution_json`. The route serialized
that JSON again. Warm requests already select the prepared representation.

The read now retains the exact selected successful snapshot. After preparation
returns, it may reuse the prepared payload only while that same snapshot is
current and fresh and the workspace matches. If invalidation or replacement
wins during preparation, the request retains its previously selected JSON.
An unpublished compute result cannot borrow later published bytes. Force and
parameterized timeout paths retain their existing behavior.

The existing `Execution_payload` route handles encoding selection, weak ETag
and conditional responses; this change adds no codec, cache, TTL or compression
policy. The identity representation and encoded representations stay together,
consistent with the existing HTTP representation handling and
[RFC 9110](https://httpwg.org/specs/rfc9110.html#field.content-encoding).

## Verification

- The first fallback starts without matching prepared bytes, then must return
  the same identity/gzip string objects as the warmed route, with matching
  ETag, headers and JSON metadata. This proves byte reuse, not latency.
- A separate case invalidates both projection and byte caches, runs the real
  first projection compute, then verifies its successful publication and
  identical identity bytes/ETag on a subsequent warm read.
- Existing preparation scenarios now check reuse against the exact selected
  snapshot: workspace mismatch, invalidation inside preparation, and a newer
  ready snapshot all reject the old selection.
- Existing force, timeout, parameterized actor and generation checks remain.

Source parsing and whitespace checks pass. Compiled CI and independent review
are pending. Codec preparation, cold projection time, scheduling/GC and network
cost remain; no 0.1ms achievement or deployed performance improvement is claimed.

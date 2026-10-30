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
- A separate case invalidates both projection and byte caches, runs the cold
  compute/publication path with the `execution_smoke` fixture, then verifies
  its successful publication and
  identical identity bytes/ETag on a subsequent warm read.
- Existing preparation scenarios now check reuse against the exact selected
  snapshot: workspace mismatch, invalidation inside preparation, and a newer
  ready snapshot all reject the old selection.
- Existing force, timeout, parameterized actor and generation checks remain.

Source parsing and whitespace checks pass. Source head
`887807abe0bfb2b3d2df7fbca7672faa199aa898` passed PR CI `36240341203` and focused
CI `36240409176` (54 cache, 133 HTTP core, two publication-attempt cases).
After integrating main's overlapping typed `Tool_timing.start ()` test change,
head `a488cf8b6b9ea142c3e551f4540737647570cbfc` passed all five PR gates
`36242653741`. Focused run `36242729288` passed the 54 + 133 cases but ended
red because I supplied a nonexistent third suite name. Corrected dispatch
`36243702742` passed the actual two-case publication-attempt suite on the same
head. The invocation failure remains distinct from those 189 passing cases.
This later evidence-only commit requires new PR gates.
Independent adversarial and response reviews found
no source defect; the added first-compute case uses a fixture projection.
The tests do not execute an HTTP fiber race through the final wire response. Codec preparation, cold projection time, scheduling/GC and network
cost remain; no 0.1ms achievement or deployed performance improvement is claimed.

## Controlled first-response measurement

The review request is now addressed by [the paired comparison](comparison/README.md):
12 isolated sessions and 480 GETs with the same synthetic task inputs. The first
post-mutation identity median was 12.823875 → 12.362959ms and gzip median was
13.020604 → 12.206542ms, with 60 samples per arm per encoding. **Both first-response
p95 and max worsened.** Gzip first responses changed from identity to gzip, so
this is not a measurement of serialization cost alone. The original unequal-path
experiment is retained separately. Source/binary identity, exact commands,
all observations, independent review and cleanup evidence are included.
No general latency improvement, deployment or 0.1ms achievement is claimed.

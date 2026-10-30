# Prepare dashboard response bytes before publication

The deployed actor response cache reused bytes on hits, but published cold and
refreshed entries with only their JSON AST. The first reader then serialized
and hashed the response on the request domain. One observed authenticated
execution response was about 1.42 MB.

Entries now hold one immutable `cached_payload`. The existing worker compute
prepares the AST, bytes and matching ETag before token-checked publication.
Fresh and stale hits return those bytes without another worker submission.
Cancellation and stale restoration keep the existing owner-token checks.

The small warming seed used by the tools endpoint is prepared synchronously
before publication. It skips preparation when a slot already exists and
rechecks during publication so a concurrent real fill wins. It does not queue
behind the expensive background refresh. Seed preparation and uncached error
envelopes still perform small serialization on the caller domain; this change
does not claim every request has reached 0.1 ms.

Focused tests cover preparation domain, publication ordering, byte/ETag
consistency, hit reuse, background refresh, a saturated worker with a warming
seed, concurrent real-fill precedence, cancellation, timeout, replacement
tokens and expired stale-byte preservation. Independent source review passed.
No local Dune build was run; CI and deployed measurements are pending.

Before this change, two live observation windows on server `2fc09f02d9` showed
authenticated execution p50 near 1.2–1.4 ms, with cold samples at 122–359 ms.
Those totals include pool waiting, projection and serialization; they do not
attribute the tail to serialization or establish a predicted improvement.

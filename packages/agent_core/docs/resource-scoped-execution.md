# Producer-owned resource scheduling

`Tool.ordinary_descriptor_scoped` lets an ordinary producer prepare an exact
input, an opaque resource claim, and the handler that consumes that claim.
The normal descriptor remains Serial and Effect_possible. The SDK neither
resolves filesystem paths nor grants permission or safe replay from a claim.

`Resource_scope.identity` namespaces exact producer-owned identities. A claim
occupies one identity and lists its complete ancestry. Two claims conflict
when they occupy the same identity or one occupies an ancestor of the other.
Sharing an ancestor alone permits disjoint siblings to run together. Producers
must canonicalize aliases and validate their resource authority themselves.

The SDK validates public inputs before preparation, then retains prepared
resources on a caller-cancellable switch through dispatch and its observers.
Preparation must not perform the tool effect. `Ok None` uses the original
Serial handler; `Error error` returns the exact error without dispatching that
handler. Producers must release partial preparation before either response.
Reserved exceptions, including cancellation, propagate. Other preparation
exceptions become an invocation-bound execution failure and stop later batches.

Prepared calls retain their exact input and handler together. Default injection
is applied consistently to both preparation and its handler; hooks and transcript
results retain the original public input. PreToolUse still authorizes each call;
an illegal AdjustParams decision aborts before its handler. A transferred scope
does not replace producer authorization or resource-binding validation.

`Tool.of_schema` and `Tool.create` bind scoped admission to the exact ordinary
handler. An arbitrary record update that replaces this handler falls back to
Serial execution of the replacement, preserving its observers and permission
checks. `Tool.with_defaults` transforms preparation and execution together and
retains their binding; a stale descriptor cannot bypass a new wrapper.

Canonical attempted or settled invocations are restored before preparation,
using the exact current provider's persisted authority and its original
schedule. They form conservative batch barriers. The existing durable
settlement returns the original result or refuses an unknown effect; a changed,
unavailable, or retired resource preparer cannot replace that truth. Fresh and
unattempted effects still require current preparation and authorization.

Within a contiguous scoped region, every earlier conflicting call is an order
dependency. Ready waves run concurrently and preserve transitive ordering;
results are returned in original planned order. Their invocation schedules
record the actual Concurrent wave. Readonly concurrent regions, ordinary Serial
calls, unknown tools, and Terminal admission retain barriers. Ordinary tool
failure results permit later batches, while hook, observer, and durability
failures stop them after preserving already completed siblings.

This SDK mechanism does not yet enable MASC Edit concurrency. That integration
must supply translated-path and pinned-capability claims, preserve the Gate,
and prove actual filesystem behavior separately. Async admission, durable
effect replay, and cross-process resource exclusion are unchanged. Scope
scheduling belongs to one tool-use batch; it does not replace a producer's
lease between separate concurrent batches.

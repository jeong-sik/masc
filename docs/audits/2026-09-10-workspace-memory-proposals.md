# Durable workspace memory proposals

The curator's `proposal.json` can now become a server-owned workspace artifact.
It remains `model_proposed`: saving it neither establishes truth nor promotes
its claims into Keeper memory or recall.

`POST /api/v1/dashboard/workspace-memory-proposals` requires `CanAdmin` and
accepts the exact curator envelope (`status`, `context_sha256`, `sources`,
`gaps`, `snapshots`, `proposal`). Successful responses contain `id`, the saved
`proposal`, and `semantic_verification: "not_performed"`.

`GET` on the same route requires `CanReadState`. Without a query it returns
`proposals`; `?id=<id>` returns one saved envelope. Missing storage lists as
empty, absent IDs return 404, invalid input returns 400, and corrupt or
unreadable storage returns 503. Clients must independently GET the returned ID
to establish readback after a POST whose outcome may be ambiguous.

Storage is `<base-path>/.masc/workspace-memory/proposals/<sha256>.json`.
The ID hashes sorted-key server JSON serialization, so clients should treat it
as opaque rather than assume their JSON float formatting matches the server.
The existing strict atomic replacement helper syncs payload and parent before
success. Repeated identical content returns the same proposal; existing corrupt
content is not overwritten. This is a server-owned store, not a multi-process
editing interface.

The decoder creates typed claims, conflicts and exclusions, rejects unknown or
uncovered source references, overlapping exclusions, duplicate identities,
unknown snapshot links, invalid evidence paths and duplicate snapshot-slot bindings. It preserves owners, full
fact objects, gaps and snapshot metadata. These checks validate the submitted
structure; source digests and model claims are not independently revalidated.

Behavior tests cover persistent readback with conflicting owners and gaps,
idempotence, refusal before writing, and missing versus corrupt storage. They also
ingest the saved local Qwen3.8-27B proposal and round-trip zero-fact retraction
evidence, rejecting duplicated fact, change and invalidation bindings.
No local build was run; compiled validation belongs to CI. Authentication and
deployment still require live HTTP verification before claiming runtime use.

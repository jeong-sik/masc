# Farm retained media-reading originals

Runtime reader declarations and the owned stdio port now have a common original
request representation. It retains the actual prepared invocation recipe and
complete verified input before a future producer may ask for approval or dispatch.
This change implements storage, restoration and install-preflight integration;
it does not activate an external reader.

## Captured request

Successful stdio preparation records the digest and length of its actual V3
Interactive frame with acceptance disabled. Its opaque binding also names the
workspace, Keeper, payload argv, actual carrier and endpoint policy. The process
carrier's ordered environment is hashed without serializing its values. Accessors
read this immutable capture; they do not reload declarations or the environment.
The decoder also accepts the exact integer representation that the canonical
original store uses for integral timeout values.

The binding describes an invocation recipe. It does not pin filesystem objects,
executable bytes, dependencies, credentials, ambient executable lookup or host
cwd. Decoding its JSON creates no executable handle. A future dispatch must use
the actual prepared request and compare it with the retained binding.

The media original joins that binding to all seven reader declaration fields,
the exact kind/MIME/Stored SHA and length, complete verified data-URI arguments,
reserved execution ID, causal origin, task and continuation channel. It accepts
no caller-provided URL or local path in place of the verified input. The reserved
ID is an identity, not evidence that a process started. Restoration recomputes
source, declaration and original digests and checks the complete saved record.

## Existing owner and store

One fixed host scope uses the existing original-request store. Its Manual host
identity describes the media adapter; it does not pretend that a MarkItDown
add-on installation or external account was admitted. Retention and load check
the canonical workspace, its observed physical root, the intended Keeper and the
store path. Workspace-root observation is separate from process-cwd pinning.

The subject excludes reader revision and continuation channel. Before selection,
discovery validates every live record and restores every body in this scope,
then selects the matching subject. A valid-looking summary with a changed subject
cannot hide an older unknown execution. Missing, malformed, changed or unreadable
records do not become an empty inventory. Multiple originals remain visible.

This complete discovery reads all live bodies; no reduced I/O or measured
performance improvement is claimed. Later batching may reuse verified observations
within their actual scope, but an unchecked summary cannot replace the body check.
The caller still owns the existing workspace lease and serialization.

The existing consumer registry now names this scope. Install preflight invokes
the original decoder after canonical store/body verification. The startup archive
pass classifies its metadata and progress references; that pass is not a complete
media-payload restore. Existing blob ownership sees the official Stored source
representation in the original body. There is no new journal or blob registry.

## Evidence and remaining work

Three new suites contain 14 authored cases: prepared binding, actual original
storage, and the real `validate-stores` helper. They cover canonical numeric
roundtrip, source/owner/declaration mismatch, prior unknown visibility, changed
summaries, missing source, workspace replacement and semantically invalid records
whose generic body hashes remain valid. Their binary fixtures are not valid DOCX
documents and no conversion occurs. Full-file OCaml parsing and whitespace checks
passed; type/link and test execution remain unverified for this change.

The effect-producing unit still needs durable approval intent/linkage, exact
observation of the existing approval queue, dispatch and unknown-outcome handling,
complete MCP reply retention before decoding, cache settlement and the actual
replay producer. The final reader integration must inspect prior originals before
current declaration/cache selection and prove an actual DOCX through the owned
SSH/guest route. Storage success does not establish those behaviors.

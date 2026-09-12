# Retained Browser Lane observations

A fast composition can read several pages between two TUI refreshes. The three-channel native evidence in #35531 includes a run where the Keeper read all three pages while the TUI displayed only the last. Retaining the completed reads lets an operator review them without delaying navigation or reading changed pages again.

## Data and lifetime

Scene and region reads validate their Browser_scene schema, observed tab, explicit source and resolved client identity. Direct Keeper BrowserRead and MCP reads bound to an actual registered Keeper use the same retention boundary. Unbound external MCP reads remain ordinary observations without hidden retained blobs. It writes the exact result data to the existing durable Tool_blob_store as application/vnd.masc.browser-scene+json before returning a reference.

Tool_result.retained_artifacts carries observer roots outside model-facing data. Tool_result.to_json intentionally omits these roots: composition serializes node results into model data, and an embedded normalized artifact reference would force Tool_bridge to externalize an otherwise inline scene. Normal configured output-size projection still applies.

The direct Keeper handler carries roots by native invocation identity through the post-tool hook. The hook clears them only when its tool-call row commits. Native MCP passes the typed result to its existing trace writer and forces synchronous append for retained observations; the lossy asynchronous preview queue cannot own their only root. Composition logs the original producer roots even when declared output validation rejects the node, and fails the node observation if that required receipt cannot commit. Existing tool_calls artifact_refs are the GC roots; there is no second browser journal or separate retention policy.

A storage failure preserves the observed data in a typed runtime failure and asks to retry only the read. It does not repeat preceding navigation. A read that never completed does not publish a retained observation. Log failure does not acknowledge a successful durable receipt. The maintenance helper requires the exclusive BasePath writer lease, so it cannot sweep pending invocation artifacts under a live server. After process termination, artifacts written without a committed receipt remain subject to the existing offline orphan maintenance policy. A pre-commit process crash is not a completed observation receipt.

## Authority and consumer boundary

A retained observation describes a past read, with the original URL, document identity, scope, viewport and truncation. It is not a live browser handle or authorization to click old references. Current-state requests and interactions require the existing live observation and identity checks. Website content remains untrusted data.

This change supplies retained records; the TUI history selection and rendering consumer is a dependent change. It does not claim to align screenshots with these observations: screenshots must have their own capture identity, and live pixels are not inferred from historical scene data.

## Validation

Tests exercise the actual Keeper read producer and the owner-bound MCP retention boundary with synthetic browser transport; persisted bytes survive subsequent navigation and disconnection. They check inline model projection, composition serialization, truncated log roots and existing GC accounting. The actual composition executor and production node observer cover successful and schema-rejected reads. Production Keeper hook tests cover missing log storage, retry, synchronous commit and distinct invocations with blank provider IDs. The native MCP trace writer is checked separately. These are not full native provider or installed-extension proofs.

A retained MCP receipt commits synchronously before the outer request audit and response observers. The executor reports its single resolved caller identity before effects; receipt ownership captures that exact identity and its registered Keeper entry, rather than repeating bearer, session-cache or workspace-alias resolution. An outer audit failure can still fail the request, but cannot strand its retained observation without a receipt. A dispatch failure before retention, including the executor's non-public-tool audit, returns an ordinary failed tool call and produces no observation artifact. Within the trace writer, append failure propagates while subsequent trajectory and SSE notifications are best-effort.

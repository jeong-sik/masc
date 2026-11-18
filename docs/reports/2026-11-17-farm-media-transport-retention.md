# Media reader transport observations

An MCP reply can arrive before the reader process is closed. The reply and
the actual transport result therefore need separate durable facts. Recording a
late receipt must not invent a domain commit or erase a retained reply.

`Lane_addon_request_progress.Transport_observed` retains one immutable link
without changing the original request's phase. The media owner validates its
original request ID, body digest, execution ID and normalized blob reference.
The referenced ordinary JSON blob preserves the complete typed execution
receipt and trailer, including signal, shim error and syscall observations.
It is not a raw stderr transcript. Blob garbage collection treats its contents
as opaque and retains the actual normalized reference.

The owner checks the current workspace, immutable original and known progress
before publication. It writes the blob before the link. An equal existing
observation is loaded and verified; missing, corrupt or conflicting evidence
is an error. An uncertain write permits reconciliation of the same evidence,
not another invocation.

`Request_not_sent` cannot coexist with a reply, and an observed invocation
cannot be dispatched again. Absence of a receipt after dispatch remains
unknown. Proven no-send can support a future original with fresh Gate authority;
this storage boundary does not grant that authority itself.

The existing protocol decoder now recognizes `refused_socket` and
`refused_write`, both already emitted by its encoder. Librarian rejects this
foreign fact, and other exhaustive progress consumers preserve their existing
meaning. A transport blob is not an edge to another original request body.

The authored cases cover late receipts, no-send contradictions, immutable
publication, lost acknowledgement, corrupt or missing blobs, normalized roots
through the real garbage collector, and complete typed codec round trips.
Existing local MCP channel cases also retain the actual callback observation
when a later callback exception or cancellation occurs.

Validation so far is independent source review and full-file syntax parsing of
the 22 OCaml files in this unit. The new and extended cases have not been run.
No type-check, SSH/microVM execution, installation or deployment is claimed.
The called producer and its retained-host/Gate integration are a separate change.

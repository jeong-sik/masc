# Durable Edit snapshots

The host-authoritative shared-mount atomic-patch path now preserves the complete pre-edit read and
completed replacement bytes in the existing content-addressed Tool_blob_store.
The successful structured result contains `edit_snapshots` with empty-preview
normalized artifact references for `before` and `after`. The original bytes
are not embedded in ordinary log previews, so trimming/redaction does not
turn previews into false exact-file evidence.

Both blobs must persist durably before references are returned. An unavailable
snapshot store is reported explicitly without reversing the already completed
file operation. File-edit success payloads are now typed JSON, so the
production hook can collect the references in the existing `artifact_refs`
retention path. No new storage root or model/runtime control gate is added.

Feature tests use the real Edit handler and production post-tool hook to
check exact full-file snapshots (including tabs and CRLF), durable artifact
references, successful editing with visible snapshot-store failure, and
cancellation injected precisely before snapshot persistence. The cancellation
scenario checks that applied success and both blobs survive while cancellation
is still delivered afterward. Post-commit snapshot/result assembly is protected;
pre-commit writes retain their existing cancellation behavior.
These OCaml scenarios await CI execution; no local build ran.

Scope: the host-authoritative shared-mount atomic patch path, including
replacement and insertion. `Endpoint_owned` execution (including remote CLI
writes) uses another owner and is not covered by this change.
Snapshots describe the successful edit's bytes, not later file state. The
chat reader/diff rendering and built browser proof remain the next dependent
slice. Requirement 15 is not complete from this producer change alone.

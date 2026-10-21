# Curator host capture and original judgment

`Workspace_memory_execution_capture` builds on the
[known-ID batch storage boundary](workspace-curator-request-capture.md). It
captures host-supplied resolved metadata and validates its internal relationships;
the production Curator owner does not yet create or dispatch these records.

A capture contains one opaque UUIDv7 request ID, the descriptor-observed physical
workspace path/device/inode, original installation/package/tool and source/config
revisions, the full resolved prompt, original classification ledger and batch or
briefing batch, actual input substitution bytes and domain output schema.
Factories reject inconsistent prompt-source/override/file flags, a different
rendered prompt or a briefing pass with a different prompt/schema contract.
Destination revisions and prompt provenance come from the trusted caller, not
from looking up current configuration in this module.

Canonical Addon storage can reorder JSON object keys. Re-serializing restored
input would therefore fail to reproduce an originally rendered prompt even
though the JSON values are equal. Retain the exact original substitution text,
check its strict JSON meaning against the whole batch, and render using that text
and the captured template. Compare the result byte-for-byte with the actual
captured prompt. Today's effective override supplies none of those bytes.

Restoration requires a private `Lane_addon_tool_request_owner.retained` from its
strict load. Its original scope, request ID and installation/package/tool must
match the capture, as must the current observed physical workspace. A record
copied to another workspace or recovered at the same spelling with a new inode
is refused. Unknown kind/schema, changed domain schema, inconsistent batch,
template or input text are errors.

The filesystem observation reuses `Fs_compat.with_owned_inventory_root`; its
immutable stat getter exposes the existing held descriptor observation. The
callback computes only a value, and the scope must finish its final identity
check before returning it. It performs no retain/RPC inside that callback.
Path/device/inode are observation, not a fresh UID/permissions check, process
lease or effect authority. In Eio, the caller runs the complete blocking scope
on a system thread, retains original workspace ownership and serialization, and
revalidates actual authority before effects.

`validate_output` computes an expected state with the existing full-domain
`Decision.decode`/`Ledger.apply` or `Briefing.decode_output`/`accept`. It does not
write the ledger, publish briefing, complete an observer or decide to retry.
The actual owner's original-flow semantic acceptance port and commit recovery
journal still have to consume this captured request.

The five `test_workspace_memory_execution_capture` scenarios use actual owner
retention and a fresh store handle, preserve exact input/render after an override
change, reject changed provenance/owner/schema, reject copied/replaced physical
roots, preserve a briefing's private chunk and test the held-root final check.
Parser/source review are not compiled execution or live worker/UI proof.

Remaining E02 work includes production metadata capture, accepted-work inventory
and lifecycle, original-flow semantic validation and typed failures, uncertain
commit recovery, Addon wake delivery, worker execution, Off/reconnect and both
UIs. This module does not complete any of those integration requirements.

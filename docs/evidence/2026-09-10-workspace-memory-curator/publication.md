# Store and read back a curator proposal

Add `--publish-url http://localhost:PORT/api/v1/dashboard/workspace-memory-proposals`
and `--publish-token-file PATH` to a curator run to submit its complete saved
proposal to the authenticated MASC proposal store. The publication credential
is separate from the input credential and is never sent to the local model.
The server endpoint requires admin permission. Local file generation remains
the default; publication is explicit.

The client keeps the locally generated proposal, posts that exact envelope,
then independently reads `?id=SERVER_ID` and compares the complete decoded JSON
with the saved proposal. A server acknowledgment alone is not readback proof.
HTTP status and raw response artifacts are retained (literal credential echoes
are withheld). No redirect or environment proxy is used.

`publication.status` records attempted, acknowledged or readback_verified.
`runtime_mutation` is null after a POST attempt until exact readback succeeds:
a failed observation cannot prove the remote write did not happen. The local
proposal remains available on failure. Success stores a model_proposed artifact;
it does not promote facts, verify semantics, or inject Keeper recall.

Twelve local HTTP scenarios exercise the CLI, including complete live-source to
model to proposal-store readback, separate credential boundaries, publication
failure and mismatched readback. These are HTTP fixture tests, not deployment
proof. The OCaml endpoint is being delivered as a separate server work unit.

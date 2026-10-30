# Curator captured requests: storage and batch boundary

This implements the known-request recovery foundation of
[the E02 execution contract](workspace-curator-addon-execution.md). It does not
switch the production Curator owner to an Addon.

`Workspace_memory_request.batch_to_json/batch_of_json` retain complete selected
and remaining facts, original input rows, neighbors, related ledger prose,
rendered prompt and index observations. Restoration uses the captured ledger,
not a new retrieval. It rejects changed identities/hashes/prose, repeated facts,
already disposed pending facts and same-Keeper neighbors. Narrowing preserves
original cumulative index observations. The shared ledger fact-reference codec
keeps existing fact IDs and full-ledger disposition decoding unchanged.

`Workspace_memory_briefing.batch_to_json/batch_of_json` restore the original
private pass, prior publication, selected chunk and ordered remainder. The chunk
partition must equal the pass's complete unconsumed sources, and model input must
match its original semantic summary and selected sources. Restoration does not
prepare, accept or publish a summary. Normal host acceptance still controls
whether a chunk advances the pass or publishes its complete result.

`Lane_addon_tool_request_owner.retain` now saves the complete canonical request
alongside its digest and immutable installation/package/tool destination in the
existing verified durable store. `load` validates the closed record, original
storage key and complete request digest. Duplicate/nonfinite JSON is refused
before publication. Invalid captured input has its own `Invalid_request` variant;
the existing Runtime and Candle transport mappings reject it as host input.
Equivalent canonical input can reuse its original binding; another destination
or input cannot replace it. Missing keys are distinct from damaged/unreadable
records. Existing incomplete records are errors, with no migration or synthesized
request. No live runtime data is rewritten by this change.

The caller still holds the workspace process lease and serializes competing
retains; loading does not establish physical workspace authority or dispatch
permission. Keeping full requests increases retained bytes and read/validation
work. The existing store durability/read implementation is reused unchanged.

The batch codecs preserve prompt bytes but do not prove their provenance. Before
production wiring, the trusted host envelope must capture and verify physical
workspace identity, effective template/schema/config revisions, original ledger
or pass and destination. Restart enumeration, accepted-work lifecycle, semantic
validation before original HTTP/CLI candidate acceptance, uncertain commit
recovery and Addon On/result wake delivery remain required by E02. A known-ID
load does not provide any of those guarantees.

Verification targets are `test_workspace_memory_capture`,
`test_workspace_memory_request`, `test_workspace_memory_ledger`,
`test_workspace_memory_briefing`, `test_lane_addon_host_cycle` and
`test_candle_appraiser_transport`. The new capture tests reopen the actual durable
store, apply a restored selected classification, resume a briefing chunk without
early publication, and exercise destination conflicts, damaged records, invalid
JSON and failed publication. Source review and parser checks are separate from
compiled execution results and real host/worker/UI evidence.

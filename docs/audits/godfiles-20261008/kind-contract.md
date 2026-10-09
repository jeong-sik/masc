# Chat kind contract audit

Source inspected: `4a08c8a2bee6862297cae4a2cc3db00d231b854b`.
Local evidence: [local-validation.md](local-validation.md).
Scope: classify the current row discriminator's purpose before retaining or
removing it. This audit does not claim a schema removal or rendered UI proof.

## Required distinction and avoidable representation

A Keeper's actual utterance may acknowledge its matching user input. A server's
failed-request announcement must not acknowledge that input or enter the
Keeper's conversation memory as its own words. This behavioral distinction is
necessary. An independent `role × kind` product is not a requirement of that
behavior; it currently compensates for storing a server announcement as an
assistant row.

The actual producing chain is:

- `server_routes_http_keeper_stream.append_queued_assistant_once` and
  `append_queued_transport_failure_once` choose `Terminal { content; kind }`.
- `server_keeper_operation_transcript.persist` feeds both into
  `keeper_chat_store.append_assistant_message_once`.
- That writer assigns both `Role.Assistant` and `Terminal_assistant` provenance.
- `keeper_owner_registry.record_restart_interruptions` uses the same writer for
  a server restart announcement.

The row-kind consumers then recover the lost authorship distinction:

- `keeper_world_observation_message_scope` excludes failure announcements from
  recent direct conversation and from pending-input acknowledgement.
- `keeper_tool_surface_ops` excludes failure rows when selecting a delegate reply.
- `keeper_surface_read` exposes the marker when a Keeper reads its own lane.
- `keeper_chat_journal_audit` compares terminal journal events with persisted rows.
- Dashboard `keeper-state` and TUI `masc_tui_keeper_chat_history` turn the marker
  into a failure display after history reload.

The repaired unknown-kind parser prevents an unrecognized or malformed value
from turning a server announcement into an acknowledged reply. The executed
three-test group confirms that repair and the existing omitted-kind contract.
It does not establish that the current representation should be retained.

## Operation state alone is not an equivalent replacement

`keeper_chat_operation.state` already owns typed operation terminal facts.
However, `server_routes_http_keeper_stream.operation_execution_of_outcome` can
convert `Delivered { outcome_ref }` with a later delivery error to
`Operation_failed Delivery_failed`. A failed operation is therefore not by
itself proof that no actual Keeper speech was persisted. Replacing row kind
with a lookup of `operation.state = Failed` would conflate distinct facts.

Likewise, merely changing failure rows to `Role.System` fails the current
provenance contract: `validate_delivery_role` requires the
`Terminal_assistant` slot to have an assistant role. TUI history currently
classifies generic system rows without approval payload as memory activity.
Those boundaries must change together in a coherent removal.

## Source-established media defect

The failure writer deliberately retains completed media blocks from
`Keeper_stream_media_accum` for history reload. Its comment and
`persist_failure_reply` implementation state this ownership explicitly.
Dashboard `ChatMessage` in `components/chat/primitives.ts` nevertheless sets
`effectiveBlocks` to `[]` for a failure message and chooses a diagnostic-only
`ChatFailureCard`. The TUI failure-history branch emits diagnostic text with
empty attachments and bypasses its normal assistant block projections.

Consequently a media block completed before a later terminal failure is
persisted but excluded by those reload rendering paths. This is a pre-existing
consumer defect established from the producing and consuming source. It has
not been reproduced in a browser or PTY in this audit. Treat it as a concrete
repair and validation obligation, not as a rendered regression already proved.

## Next structural repair

Remove the fake assistant-speech producer and model actual Keeper speech and
server-owned failure receipts as separate closed rows. Tie a failure receipt to
its operation and preserve its exact turn/surface/conversation coordinates.
Update the terminal provenance slot, strict decoder, request acknowledgement,
conversation memory, journal reconciliation, delegate selection, and both UI
history readers in the same contract change. Preserve one terminal authority
and append-once behavior; separate slot names must not allow contradictory
terminals to append for the same operation.

Carry already completed tools and media independently of the terminal failure
receipt and render their retained output without acknowledging the failed
input. Verify failure-after-output, restart recovery, retries, reload and
unanswered-input continuity. Remove the independent `kind` field when these
obligations hold under the new row contract; do not replace it with another
unconstrained string or keep a compatibility writer/reader.

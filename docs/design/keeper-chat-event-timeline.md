# Keeper chat event timeline

The chat timeline consumes normalized events from both direct chat and autonomous
Keeper execution. Provider messages, tools, and reasoning need separate identities:
reasoning must not occupy the public answer's content index, and a native tool's
observed end does not prove successful execution.
Repeated active observations with the same provider tool identity retain one
content index, so the later end closes the original chat occurrence.

This matrix describes the source in this change. It is not a live vendor test or
an installed-binary verification.

The TUI stores each journal's source as either a chat operation or an autonomous
`turn_ref`. Operation pages use `/chat/events`; autonomous pages use
`/turns/:turn_ref/events` and `masc.keeper_turn_events.v1`. An observer growth
notification requests a journal read after the last accepted sequence, without
appending content from the notification itself. Current-turn polling and history
pages also discover these sources, so opening the pane after a turn started or
after it ended does not require a new token notification. Live SSE timestamps and
replayed journal timestamps both retain the server's epoch-seconds clock.

The operation SSE subscription buffers live events through acceptance and replay.
A single sender then drains that queue, including events arriving during the
drain, before releasing sender ownership. The state lock never covers a send.
Rejection, release and send failure close the queue; a publisher holding an old
subscription callback cannot reactivate it. Replay still deduplicates exact
sequence membership, retaining a buffered event if its journal append failed.
Live subscriptions and terminal accounting are keyed by canonical runtime base,
Keeper and operation ID, matching the owner registry's authority and each Keeper's
operation store. Reusing a request ID in another Keeper or runtime cannot share
its live audience, consume its terminal record or unregister it.

Inputs remain in a separate pending area through local dispatch, unconfirmed
transport, and server queue admission. `Run_started` or an authoritative persisted
input proves processing began. A verified refusal keeps the original input text
and displays its error separately. A batch retains each input identity,
including identical consecutive messages, while all bound inputs precede one shared
response. Each output stretch keeps its server event time and continuation segment;
resuming an operation cannot move a later answer above an intervening input or replace
an earlier segment's text. Autonomous journals end at their own turn boundary even
when their outcome is a continuation checkpoint for a later turn.

Provider message starts, tool rounds, retries, and continuation segments open a
new response window. When only one text stretch was observed in that window,
a flat canonical reply replaces it while retaining its source origin. When more
than one was observed, their text and reasoning stay at their original positions,
marked `SAYING` in the gutter; a separate `FINAL` row carries the recorded reply
at its actual reply-event time. These labels are outside the authored body. Thus
A/thinking/B stays intact, and canonical AB is never substituted for just B or
moved ahead of the original thinking. Hidden reasoning does not change this choice.
The layout entry carries an explicit heading boundary for these speech sections,
so metadata-row mode retains their labels without parsing speaker text. All
ordinary entries inherit existing turn headings, including anonymous replies and
retry labels; the new sections do not alter request identities or turn rails.

`Reply_details` currently contains flat canonical text, not a correspondence to
provider content blocks. Official-client adapters may already flatten their
content, and finalization can normalize the body again. This fallback therefore
preserves observations and final authority separately. A producer with canonical
blocks must retain their original message/block provenance through finalization
before an in-place multi-block reconciliation can be introduced; string prefixes,
positions in the final string and reconstructed block indices cannot supply it.
Text and reasoning origins are allocated across the whole operation, without
resetting at retry or continuation. Tool groups use their first local call's
identity; records without streamed text have explicit synthetic origins. Rendering
visibility and array positions do not define these identities.

Message-start usage seeds the current provider response's counters. Later sparse
usage reports replace only present fields, including explicit zero values. A new
message, retry, or continuation clears the previous counters and stop reason.
The producer bridge suppresses exact message-start prelude replays within its open
stream scope before journal or SSE publication. Conflicting starts publish only
protocol errors. Every published start therefore opens a fresh response, even if
a later sealed scope reuses the provider's message id. Journal/transport replay
is deduplicated by sequence, not message-id text. Live SSE decoding and journal
replay preserve the same message identity and usage fields already present in the
server events; no new wire format is required. Historical journals written before
this producer normalization may contain distinct-sequence prelude replays. Their
flat start events carry no stream scope, so replay treats each recorded start as
a boundary rather than guessing from provider-id equality. This change does not
claim to reconstruct missing scope provenance in those older journals.

| Runtime | Turn and text events | Thinking | Tools and progress |
| --- | --- | --- | --- |
| Codex app-server | `Turn_started` becomes `MessageStart`; agent-message deltas and completed-item suffixes become `TextDelta`; terminal completion becomes `MessageDelta` and `MessageStop`. Item IDs separate messages within a turn. | `item/reasoning/summaryTextDelta` and `item/reasoning/textDelta` become `ThinkingDelta`. The item ID and summary/content index identify each part; completed reasoning contributes only missing suffixes. | Dynamic tools carry call IDs and argument snapshots. Native `item/started` and `item/completed` produce observed start/end with identity and name. Known completed-item status and nullable command exit code remain native metadata. Command output deltas carry byte observations; MCP progress carries a redacted message, attached only to its active native item. File-change output notifications are outside this contract. |
| Claude Code | Partial SDK text and complete assistant envelopes contribute text once. `message.id` separates responses; the first response opens the normalized turn and the result closes it. | Partial `thinking_delta` and complete thinking blocks become `ThinkingDelta`; complete blocks contribute only missing suffixes. Signatures and redacted payloads are not displayed as text. | MASC MCP callbacks provide dynamic-tool identity/arguments. Assistant `tool_use` and user tool results provide native observed start/end with the tool result’s optional `is_error` flag. `tool_progress` keeps transport activity alive but is not projected as chat progress. |
| Antigravity | Init opens the normalized turn; step text and terminal response reconciliation provide text; result closes the turn. Step index identifies the source. | No typed thinking event exists in this adapter. `Internal` is not established as a reasoning payload. Thinking support is unverified. | MCP callbacks provide dynamic-tool events; tool steps provide native observed start/end using conversation ID and step index. `Done` reports native completion; `Step_error` reports a native error. Neither is a MASC execution receipt. |
| GLM Coding | The configured `openai-compatible-http` route uses AGENT_CORE SSE parsing with message start/stop, text deltas, and indexed blocks. | Provider reasoning fields accepted by the configured streaming dialect produce `ThinkingDelta` or `ReasoningDetailsDelta`. Absence of a provider reasoning payload produces no invented thinking. | Indexed tool calls carry their IDs, names, and argument deltas. MASC execution receipts determine tool execution results. Official-client native-tool notifications do not apply to this HTTP route. |

## Source boundaries

- Codex: [`runtime_codex_app_server.ml`](../../lib/runtime/runtime_codex_app_server.ml),
  [`keeper_codex_runtime.ml`](../../lib/keeper/keeper_codex_runtime.ml).
  The installed Codex app-server schema identifies reasoning by `itemId` plus
  `summaryIndex` or `contentIndex`, and completed reasoning has `summary` and
  `content` string arrays.
- Claude Code: [`runtime_claude_code.ml`](../../lib/runtime/runtime_claude_code.ml),
  [`keeper_claude_code_runtime.ml`](../../lib/keeper/keeper_claude_code_runtime.ml).
  [Claude's streaming protocol](https://platform.claude.com/docs/en/build-with-claude/streaming)
  defines thinking deltas separately from opaque signature deltas.
- Antigravity: [`runtime_antigravity.ml`](../../lib/runtime/runtime_antigravity.ml),
  [`keeper_antigravity_runtime.ml`](../../lib/keeper/keeper_antigravity_runtime.ml).
  The runtime currently forwards any nonempty step text before checking the step
  type, including `Internal`, `Tool`, and `Unrecognized`. Classifying those as
  answer, tool output, or thinking needs authoritative vendor payload semantics.
- GLM Coding: [`runtime.toml`](../../config/runtime.toml),
  [`streaming.ml`](../../packages/agent_core/lib/llm_provider/streaming.ml)
  (`project_openai_chunk`).
- Chat projection: [`keeper_chat_agent_core_stream_bridge.ml`](../../lib/keeper/keeper_chat_agent_core_stream_bridge.ml).
  Native start/end observations remain separate from MASC execution receipts.
  Neither an observed block end nor a stream stop supplies a missing tool result.

## Evidence and limits

Fixture cases in [`test_runtime_codex_app_server.ml`](../../test/test_runtime_codex_app_server.ml),
[`test_runtime_claude_code.ml`](../../test/test_runtime_claude_code.ml), and
[`test_keeper_claude_code_runtime.ml`](../../test/test_keeper_claude_code_runtime.ml)
cover reasoning before native tools and answers, reasoning/text index separation,
partial/completed reconciliation, active-turn identity, and rejection of a thinking
delta aimed at a public text block. The Antigravity fixture in
[`test_runtime_antigravity.ml`](../../test/test_runtime_antigravity.ml) sends repeated
active steps through runtime parsing, the Keeper adapter, and the chat bridge,
checking one native occurrence and one observed end for either done or error.
These cases require execution in the normal
verification environment; syntax parsing alone does not establish their behavior.
Response-boundary and usage coverage also includes raw Agent Core content blocks
through the Keeper bridge, server SSE projection and journal replay in
`test_tui_keeper_chat_log.ml`, boundary/origin fixtures in
`test_tui_keeper_chat_transcript.ml`, and hidden/folded/full reasoning rendering in
`test_tui_chat_response_origins.ml`.

Provider-internal subturns are not fabricated as completed Keeper turns. Claude and
Antigravity native progress and Antigravity reasoning remain separate capabilities. Provider omissions and opaque signatures cannot be
recovered by a renderer.

Keeper operation events and autonomous journal notifications carry a typed runtime
audience in the SSE delivery record. The audience is built from the canonical
workspace base path, using the same resolver as Keeper registry identity. SSE
registration retains its authenticated root; live delivery and replay require that
root to match. External subscribers without a root receive only unscoped events.
WebSocket upgrades bind their root before subscribing, and dashboard authentication
cannot change it. gRPC subscriptions use the service's workspace root and a unique
subscription occurrence id, independent of agent name or wall-clock time. Other
global broadcast categories retain their existing audience contracts.

The two-runtime fixtures in `test_sse_stream.ml` exercise the actual operation and
autonomous publishers, live SSE, replay, and external subscribers with identical
Keeper/operation identities. `test_ws_transport.ml` checks the upgrade/hello root
binding; `test_grpc_workspace.ml` opens actual Subscribe handlers for the same
agent in two roots and verifies sibling subscriptions survive another's closure.
These are source-added regression cases, not a claim that this change was executed
in a local application or deployment.

## Native completion reports

`Runtime_native_tools.completion` retains provider completion evidence separately
from a physical MASC tool execution. A native report never emits `Tool_result_ready`,
never invents `execution_id`, and never changes a native row to MASC `Returned` or
`Failed`. Compact/full rows and the result detail show the same typed observation.
Reported errors, declines and nonzero exit codes remain in the compact trouble
row when the block is large enough to fold into separate inventory/trouble rows.

| Source field | Typed observation | Meaning on the pane |
| --- | --- | --- |
| Codex known tool `status=completed` | `Completion_reported` | Native completion reported; no inferred successful exit. |
| Codex `status=failed` / `declined` | `Error_reported` / `Decline_reported` | Provider error / decline reported. |
| Codex command `exitCode` | `exit_code : int option` | Retain explicit zero, nonzero, negative, or absence independently of status. |
| Claude tool result `is_error=true` / `false` | `Result_received {is_error=Some ...}` | Error reported / no error reported. This does not establish that execution occurred. |
| Claude tool result without `is_error` | `Result_received {is_error=None}` | Result received; error flag not reported. This is a normal optional field, not malformed input. |
| Antigravity `Done` / `Step_error` | `Completion_reported` / `Error_reported` | Native completion / native error reported. |
| Generic block stop or absent provider status | `End_observed` | End observed; outcome not reported. |
| Unrecognized Codex status string | `Unrecognized_status` | Preserve the reported status, without assigning success or failure. |

Codex evidence is its installed 0.160.1 app-server contract:
[ThreadItem](https://github.com/openai/codex/blob/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/ThreadItem.ts)
and [CommandExecutionStatus](https://github.com/openai/codex/blob/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/CommandExecutionStatus.ts).
Claude Code 2.1.292's installed `tool_result` schema makes `is_error` optional;
[Anthropic's tool-result contract](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls)
also gives successful examples omitting it. The installed CLI documents that an
error flag can accompany rejection, permission denial, interruption or cancellation,
so no native error becomes proof of an executed MASC tool.

The Keeper adapter calls the typed completion observer at the original native
block index before its generic block stop. The chat producer stamps the current
stream scope immediately and transports the report on the same worker FIFO.
Autonomous turns process both callbacks under the existing stream mutex. The
bridge requires an already-open native occurrence at that scope/index with matching
optional call ID; mismatched scope, ID, or MASC authority publishes a mapping error.
A matching report closes the native row once; subsequent generic stops and repeated
reports cannot create another end. No completion guesses identity from a name or
from tool text. Missing starts/identity are not repaired by creating synthetic tools.

The journal and `KEEPER_NATIVE_TOOL_END` custom event carry the same `completion`
object. End events with no such member mean `End_observed`; a present
malformed object is a decode error, including duplicate keys and fields outside
the selected outcome variant. Unknown status text goes through redaction and
terminal text sanitization. This unit does not preserve native output/progress,
result content, elapsed duration, or a vendor-native execution receipt. Muse retains
its existing unknown completion semantics; GLM Coding HTTP argument ends still wait
for the actual MASC execution callback.

Actual Codex command items, Claude assistant/tool-result envelopes, and Antigravity
step fixtures pass through their runtime parsers and adapters into
[`native_tool_outcome_fixture.ml`](../../test/native_tool_outcome_fixture.ml). That
helper uses the production bridge, journal codec, server SSE encoder, live decoder,
log and transcript projection to compare reports and display. Additional cases in
[`test_tui_native_tool_outcomes.ml`](../../test/test_tui_native_tool_outcomes.ml)
cover unknown ends, duplicate stops, wrong scope/ID/authority, absent versus malformed
metadata, and unchanged HTTP execution receipts. These tests are authored, not
locally executed; syntax parsing is not type checking or runtime proof.

## Provider response and Keeper turn status

The TUI retains `KEEPER_STREAM_MESSAGE_STOP` in both live and journal projections.
It ends the model activity label (`STREAMING` or `THINKING`) while the Keeper turn
can remain in progress, including pending tool work or final-response persistence.
A new provider response, retry, or continuation establishes its own activity.
Empty text/thinking chunks do not resume activity. Provider stop does not erase
speech, settle tool receipts, or complete the Keeper turn.

## Codex native progress

The Codex 0.160.1 app-server contract carries exact thread, turn and item identity
in [CommandExecutionOutputDeltaNotification](https://github.com/openai/codex/blob/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/CommandExecutionOutputDeltaNotification.ts)
and [McpToolCallProgressNotification](https://github.com/openai/codex/blob/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/McpToolCallProgressNotification.ts).
The runtime retains the active item's typed kind from start to completion,
independently of idle-window tracking, which can clear while background tools
continue. Command deltas attach only to a command item; MCP messages attach only
to an MCP item. Missing/blank item identity, unstarted items, wrong item kinds and
completed items cannot create a new row or update another one. Thread/turn identity
and payload type are validated before projection.

Nonempty command deltas become `Output_observed {byte_count}`. This is the UTF-8
byte length of the decoded delta, not a token count, total process output size,
execution receipt or success. Whitespace counts; an empty delta has no output
bytes and emits no output observation. The delta body is then discarded. Equal
successive deltas are separate observations and both count. An MCP message becomes
`Message_reported {message}` after whole-value secret redaction at the bridge.
Messages are full observations, not concatenated fragments: every message remains
in the journal and the current tool row shows the latest one.

Adapters look up the exact existing native index without allocating a start.
The direct producer captures its current scope and enqueues the typed observation
on the same worker FIFO as ordinary content and native completion. The autonomous
producer applies it under the existing stream mutex. Progress is an observation
on an existing native row, not a model-content boundary: it never flushes the text
redactor. An earlier model-text fragment may remain safely withheld while progress
is published, just as with a ping. Journal sequence is safe-publication order;
it does not reconstruct the provider's original chunk reception order. Authored
text retains its own order, and progress adds no speech/tool-start row or origin.
The bridge accepts only a currently active native occurrence with the
same scope/index/call ID; ended, stopped, cancelled, superseded and MASC-owned
occurrences cannot be changed by progress. Repeated journal sequences deduplicate
in the log, while distinct progress sequences remain distinct observations.

`KEEPER_NATIVE_TOOL_PROGRESS` and the journal `native_tool_progress` event carry
the same strict progress object. Unknown variants, duplicate keys, incompatible
variant fields and invalid byte counts are unreadable data. The TUI retains the
last journal/SSE observation timestamp (with receipt-time fallback for unstamped
local deltas) and elapsed time from the tool's observed start to that update. This
is observation timing, not provider-reported execution duration. Compact Tools rows
say `output arriving` while active and `output observed` after the step ends, without
generated elapsed time; observation elapsed time belongs to Full and byte counts
belong to Full/Results detail. MCP
messages use terminal-safe display. Progress updates do not touch authored speech,
Thinking/Streaming phase, native completion, or MASC execution identity/outcome.

The actual Codex protocol fixture in `test_runtime_codex_app_server.ml` passes
command/MCP notifications through the runtime receiver and Keeper adapter into
`native_tool_outcome_fixture`, which runs the production scoped text redactor,
bridge, journal codec,
server SSE encoder, live decoder, replay log and Tools projection. It includes
repeated UTF-8 deltas, whitespace/empty chunks, interleaved assistant text, absent
and wrong item IDs/kinds, late events and redacted/control-bearing MCP messages.
`test_tui_native_tool_progress.ml` covers duplicate replay sequence, exact scope and
ID reuse, cancelled/stopped occurrences, strict nested payloads, stable model phase,
and the actual autonomous callbacks and on-disk journal. The direct serving worker
FIFO is source-inspected; the shared helper does not execute that HTTP worker and
is not evidence of a complete direct-route run. No local build or tests were run.

This unit does not retain raw command output, expose native result bodies, infer
progress percentages, or introduce provider subagent relationships. The installed
version's [FileChangeOutputDeltaNotification](https://github.com/openai/codex/blob/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/FileChangeOutputDeltaNotification.ts)
contract says the server no longer emits that notification, so it is not promoted
to a progress source. Claude parent/child progress and Antigravity progress need
separate source contracts. GLM HTTP execution tools and their receipts are unchanged.

Progress redaction regression cases configure an exact Keeper secret, stream its
prefix, publish native progress, and only then stream its suffix and newline.
The prefix must remain unpublished at the progress observation. After the complete
record is available, both direct Scoped projection and the actual autonomous
on-disk journal must contain redacted text; concatenating their text events must
not reconstruct the secret. The same check includes streamed Thinking. Native
completion and ordinary block start/stop remain separate content boundaries;
this progress repair does not redesign those existing redaction boundaries.

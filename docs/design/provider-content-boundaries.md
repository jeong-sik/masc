# Provider content boundaries

Codex and Claude content can remain open while a native tool completes. A
tool result closes that tool occurrence; it does not end the model's Text
or Thinking. The runtime preserves the provider's content completion separately
so a subsequent redactor can finalize only the content that actually ended.

## Runtime and adapter contract

| Producer | Content identity | Completion authority |
| --- | --- | --- |
| Codex agent message | `itemId`, or the existing unnamed-current-item association | `item/completed` after reconciling its final text |
| Codex reasoning | item ID and typed `Summary index` / `Content index` | the reasoning item's completion, after its missing suffixes |
| Claude partial content | message ID, SDK block index, Text/Thinking channel | both the block stop and complete assistant-envelope reconciliation |
| Claude complete-only content | assistant envelope UUID and parsed content ordinal, plus channel | the complete envelope itself |

Codex emits `Text_completed` / `Thinking_completed`. Claude delta events carry
`content_block` and emit `Content_block_stopped`. An exact repeated completion
does not close a second block. `Text_completed.source` distinguishes an exact
item from an anonymous prefix that the runtime actually reconciled. The adapter
can adopt an unnamed block only with that explicit provenance. A delta after a completed Codex item or a stopped
Claude partial block is a protocol error. Claude permits the already-supported
complete-envelope suffix after the partial stop, before publishing its normalized
content stop. Empty partial blocks need no complete envelope.

Keeper adapters allocate a unique index for each content identity alongside
tool indices. Index 0 remains reserved for the first public text block; later
text, thinking and tool occurrences use the shared allocator. A late completion
looks up its own content identity instead of closing the most recently displayed
text. Native completion callbacks still precede their own native block stop.
They do not produce a model content stop. A terminal reply suffix gets a fresh
index if the earlier model block has already closed.

The adapter forwards normalized `ContentBlockStop` for the exact index.
This is not a `MessageStop`, a turn completion, or a MASC execution receipt.
Existing chat event and journal schemas remain unchanged.

## Provider evidence

Codex rust-v0.160.1 declares an item ID on
[agent-message deltas](https://raw.githubusercontent.com/openai/codex/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/AgentMessageDeltaNotification.ts)
and an item plus thread/turn identity on
[item completion](https://raw.githubusercontent.com/openai/codex/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/ItemCompletedNotification.ts).
[Reasoning deltas](https://raw.githubusercontent.com/openai/codex/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2/ReasoningTextDeltaNotification.ts)
also identify their content part. MASC's runtime already accepts model deltas
while a background command remains open; its idle-window fixture covers that
provider lifecycle separately from content projection.

Installed Claude Code 2.1.292, SHA256
`97a01e5bc74a199e67189435d0331ea3a24eac2e07db4b76d9148c5b0386138f`,
was inspected as source bytes. Its `eS` function forwards root SDK stream events
(offset 217187558), and `RHr` normalizes complete assistant content per block
using `J8e` for the block UUID (offset 195382410). Fixtures representing separate
complete blocks therefore use separate UUIDs. The runtime accepts both existing
per-block and aggregate complete-envelope forms. These are source observations
and scripted fixtures, not a captured leak or a live-session validation.

## Validation and remaining work

Runtime/adapter fixtures cover completion before an unnewline tool boundary,
background native completion while model content stays open, repeated item
completion, a late old Thinking envelope while a new Text block is open,
duplicate partial stops, distinct same-message/same-text envelopes versus an
exact UUID replay, empty aggregate envelopes, and rejection of deltas after closure. Existing
multi-message, partial suffix, reasoning-part and native-outcome fixtures retain
their content assertions with the additional model stops.

This unit does not repair the shared redactor's one-held-block policy or the
direct/autonomous completion callbacks that still flush all held model content.
Those remain security-sensitive follow-up work: buffers must belong to a typed
scope/index/channel, unrelated starts/stops and exact same-scope header replays
must not finalize them, and genuine content/scope/attempt/request endings must
still release the appropriate safe content. Antigravity's step completion is
not yet projected as a model-content end; GLM continues to use its existing
AGENT_CORE content events. No new provider payload is inferred for either.

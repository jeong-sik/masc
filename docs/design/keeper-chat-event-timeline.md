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

Inputs remain in a separate pending area through local dispatch, unconfirmed
transport, and server queue admission. `Run_started` or an authoritative persisted
input proves processing began. A verified refusal keeps the original recall text
and marks the displayed input as rejected. A batch retains each input identity,
including identical consecutive messages, while all bound inputs precede one shared
response. Each output stretch keeps its server event time and continuation segment;
resuming an operation cannot move a later answer above an intervening input or replace
an earlier segment's text. Autonomous journals end at their own turn boundary even
when their outcome is a continuation checkpoint for a later turn.

| Runtime | Turn and text events | Thinking | Tools and progress |
| --- | --- | --- | --- |
| Codex app-server | `Turn_started` becomes `MessageStart`; agent-message deltas and completed-item suffixes become `TextDelta`; terminal completion becomes `MessageDelta` and `MessageStop`. Item IDs separate messages within a turn. | `item/reasoning/summaryTextDelta` and `item/reasoning/textDelta` become `ThinkingDelta`. The item ID and summary/content index identify each part; completed reasoning contributes only missing suffixes. | Dynamic tools carry call IDs and argument snapshots. Native `item/started` and `item/completed` produce observed start/end with identity and name. Command/file output deltas and MCP progress messages are not projected as chat progress. |
| Claude Code | Partial SDK text and complete assistant envelopes contribute text once. `message.id` separates responses; the first response opens the normalized turn and the result closes it. | Partial `thinking_delta` and complete thinking blocks become `ThinkingDelta`; complete blocks contribute only missing suffixes. Signatures and redacted payloads are not displayed as text. | MASC MCP callbacks provide dynamic-tool identity/arguments. Assistant `tool_use` and user tool results provide native observed start/end. `tool_progress` keeps transport activity alive but is not projected as chat progress. |
| Antigravity | Init opens the normalized turn; step text and terminal response reconciliation provide text; result closes the turn. Step index identifies the source. | No typed thinking event exists in this adapter. `Internal` is not established as a reasoning payload. Thinking support is unverified. | MCP callbacks provide dynamic-tool events; tool steps provide native observed start/end using conversation ID and step index. `Done` and `Step_error` currently collapse to the same native end event. |
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

Provider-internal subturns are not fabricated as completed Keeper turns. Native
progress payloads, native success/failure outcomes, and Antigravity reasoning remain
separate missing capabilities. Provider omissions and opaque signatures cannot be
recovered by a renderer.

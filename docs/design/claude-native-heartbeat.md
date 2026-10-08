# Claude root native heartbeat observations

Only `tool_progress` with `heartbeat: true` is preserved as `Heartbeat_reported { elapsed_seconds }`. Exact session, literal `parent_tool_use_id`, current open root native invocation and tool name must match. Progress `tool_use_id` remains opaque; no prefix parsing supplies identity.

The per-runtime-invocation registry records start envelope UUID, block ordinal and typed parent scope. Exact UUID replay and conflicting UUID reuse are ignored. Unknown result scope retires heartbeat authority; a child result cannot close a known root invocation. Invalid or duplicated identity fields, foreign sessions, child calls, ambiguous starts and pre-start/closed calls do not fail a healthy turn. Existing bridge validation additionally requires captured stream scope and exact active native occurrence.

Provider elapsed seconds are separate from local arrival time and local elapsed duration. A later report may decrease. Progress uses existing direct FIFO and autonomous mutex callbacks, never flushes held model content or changes authored text/model activity, and is not a MASC execution receipt or success inference. Safe-publication journal order can put a side observation before a safely withheld text tail.

## Installed contract evidence

Inspected Claude Code 2.1.292 binary: `/Users/dancer/.local/share/claude/versions/2.1.292`, SHA256 `97a01e5bc74a199e67189435d0331ea3a24eac2e07db4b76d9148c5b0386138f`. Byte positions refer to this exact binary:

- Around 184619746, SDK tool-progress schema requires tool ID, name, nullable parent ID, integer elapsed seconds, UUID and session; heartbeat is optional.
- Around 193301590, heartbeat producer reports floored elapsed seconds; wrappers around 193328511/216564073 select the actual parent ID. Around 193347325/216563914, the heartbeat producer is gated to the root invocation.
- Around 198843055, root serialization emits heartbeat true and those IDs, UUID and elapsed value. Around 184490875, user-result envelopes require nullable parent scope.

Child/subagent progress, shell progress without heartbeat and retry metadata remain unsupported. No provider ID collision is claimed as a witnessed incident; ambiguous ownership is refused defensively.

## Consumers and validation boundary

Fixtures cover runtime/adapter/scoped redaction/bridge/SSE/live/durable TUI replay and actual autonomous journals; Text/Thinking split-secret cases assert no unsafe prefix release. They include UUID replay/conflict, decreasing elapsed, malformed/duplicate fields, unknown/child/closed ownership, old bridge scope, missing start, MASC-tool rejection and provider versus local elapsed/model phase checks.

Dashboard requires the companion heartbeat_reported union/validator patch on native contract #41774 (`d7bca99fe0e969195891b3efeb99f966b1c4c69e`). Runtime changes alone are not a complete release unit. Dashboard fixtures cover valid zero/decreasing reports, malformed measurements and authored text/tool receipt noninterference.

This handoff has source and parser-only checks; no build, typecheck, test execution, CI, deployment or live-screen result is claimed. The actual direct HTTP worker FIFO is inspected, not exercised by a route fixture; the receiver fixture uses its existing scoped projection path.

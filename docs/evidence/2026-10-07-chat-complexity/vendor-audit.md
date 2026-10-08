# Provider / stream boundary audit

Frozen source: `5a9d7aeac2e609a5dab261204cf89825155860b6`.

This is a source review of Codex app-server, Claude Code, Antigravity and GLM
Coding's OpenAI-compatible HTTP route through the Keeper stream bridge. No local
build, test run, vendor request or installed-binary observation was performed.
No application files were changed.

## Confirmed contribution to the shared finding

The transcript audit's buffered-to-live SSE ordering defect is reachable with the
supported `MASC_SERVING_DOMAIN_ENABLED=true` configuration. This is corroborating
evidence for that finding, not an additional finding to count.

The important challenge was whether draining `pending` can actually interleave
with a producer. `keeper_stream_send_raw` takes an Eio mutex and calls
`write_string` followed by callback-style `flush`; it does not await the flush
([server_routes_http_keeper_stream.ml:1202-1210](../../../lib/server/server_routes_http_keeper_stream.ml)).
It is therefore insufficient to assume each send yields on one domain.

The supported domain topology supplies a separate producer:

| Boundary | Frozen source evidence |
| --- | --- |
| Configuration | `lib/config/env_config_runtime.ml:233-236` exposes `MASC_SERVING_DOMAIN_ENABLED`, default false. |
| Owner installation | `lib/server/server_runtime_bootstrap.ml:992-995` installs the owner registry and operation runner with the bootstrap switch. |
| Owner execution | `lib/keeper/keeper_owner_registry.ml:241-247` passes `pool.sw` to the owner; `lib/keeper/keeper_owner.ml:1292,1319` forks the child on that owner switch and executes the runner. |
| HTTP execution | `lib/server/server_runtime_bootstrap.ml:2120-2140` starts a separate domain, creates `serving_sw`, and constructs the HTTP routes/handler there. |
| Live producer | `lib/server/server_routes_http_keeper_stream.ml:3048-3061` subscribes to the operation event bus and invokes `publish_operation_live_event` from the operation adapter. |
| Early transition | `lib/server/server_routes_http_keeper_stream.ml:3598-3605` sets `accepted := true` under `buffered_mu`, releases that mutex, then drains the detached pending list. |
| Bypass | `lib/server/server_routes_http_keeper_stream.ml:3532-3541` sends new events directly once `accepted` is true. |

A possible schedule, requiring neither a malformed provider frame nor a yield in
the HTTP send function:

1. The registered sink buffers event sequence 10 while the serving domain is
   still publishing acceptance/replay.
2. The serving domain detaches `[10]`, sets `accepted=true`, and releases
   `buffered_mu`.
3. On the owner domain, the adapter publishes sequence 11. Its sink sees
   `accepted=true`, wins the writer mutex, and writes 11.
4. The serving domain writes pending sequence 10.

The writer mutex serializes individual writes, but not the buffered-to-live
handoff. `bin/masc_tui_keeper_chat_log.ml:60-84` appends unique events in arrival
order and advances its cursor, so the sequence inversion reaches the existing
consumer; it is not corrected by provider text normalization. The transcript
audit owns the resulting UI consequence and severity. This source witness does
not establish that the user's installed server has this option enabled.

## Provider paths inspected

| Route | State transitions reviewed | Result within this audit |
| --- | --- | --- |
| Codex | Agent-message delta/completed suffix reconciliation; reasoning item/part buffers; native started/completed identity; dynamic tool indexes; terminal result selection. | No additional concrete P0-P2 established. Reasoning and tools allocate indexes distinct from public text. Repeated active native observations with a named identity reuse the active index. |
| Claude Code | Partial and complete text/thinking blocks; per-message IDs; complete native tool starts and user results; MCP callbacks; subagent message contract. | The proposed child-text contamination counterexample was withdrawn after checking the forwarding option. See exclusions below. |
| Antigravity | Step-index identity; repeated native Active updates; Done/Step_error end; MCP events held until Init; terminal text reconciliation. | No additional concrete P0-P2 established beyond explicitly documented unsupported semantics. |
| GLM Coding | `config/runtime.toml:272-275` route; native reasoning/text index allocation; tool ID/index resolution; per-chunk rollback; stop synthesis. | No additional concrete P0-P2 established. `project_openai_chunk` separates reasoning/text/tool indexes, rolls back rejected tool-bearing chunks, and closes announced blocks on finish. |
| Shared bridge | Stream-scope transitions, native/dynamic block kinds, non-input deltas at tool indexes, repeated starts, terminal close and quarantine. | No additional concrete P0-P2 established. Native text/thinking misrouting is rejected by `reject_non_input_tool_delta`. |

Primary source locations: `lib/runtime/runtime_codex_app_server.ml:1613-1750`,
`lib/keeper/keeper_codex_runtime.ml:308-470`,
`lib/runtime/runtime_claude_code.ml:1383-1477,1515-1567`,
`lib/keeper/keeper_claude_code_runtime.ml:190-306`,
`lib/runtime/runtime_antigravity.ml:771-818`,
`lib/keeper/keeper_antigravity_runtime.ml:315-447`,
`packages/agent_core/lib/llm_provider/streaming.ml:1161-1224,1244-1485`,
`lib/keeper/keeper_chat_agent_core_stream_bridge.ml:119-132,431-484,747-1280`.

## Challenged candidates not promoted to findings

### Claude subagent text is gated upstream

`parse_assistant` does not preserve `parent_tool_use_id`
(`lib/runtime/runtime_claude_code.ml:1136-1160`), and every admitted text block
would become the Keeper's public `Text_delta` (`:1534-1541`). That alone initially
looked sufficient for the counterexample parent A → child C → parent B.

It is not sufficient for the current integration. The
[official Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python#claudeagentoptions)
states that `forward_subagent_text` defaults to false: child tool-use/result
blocks are forwarded without it, but child text/thinking are not. MASC's
initialize payload does not enable that option
(`lib/runtime/runtime_claude_code.ml:852-858`). The
[streaming reference](https://code.claude.com/docs/en/agent-sdk/streaming-output#streamevent-reference)
also says raw partial events belong only to the main session. Thus a nested
partial `message_start` is not a supported witness for corrupting the one
partial-message accumulator. These docs were consulted on 2026-10-07; no actual
CLI transcript was obtained in this audit.

Loss of child tool attribution remains visible in source, but no distinct
incorrect execution receipt or user-visible false result was established from
that omission. It is not counted as a P2 here.

### Completed-only native events need a protocol witness

Codex runtime accepts an `item/completed` native tool and emits
`Native_tool_finished` (`lib/runtime/runtime_codex_app_server.ml:1694-1713`). The
Keeper adapter only emits an end when it already has an index for that identity
(`lib/keeper/keeper_codex_runtime.ml:437-451`). A completed-only fixture would
therefore have no row. However, this review did not establish that a valid live
provider stream in this integration omits the corresponding start. Parser
acceptance of a constructed frame is not proof of that production condition.

### Existing capability limits

Native output/progress payloads, native success/failure, and Antigravity reasoning
are explicitly listed as missing capabilities in
[`docs/design/keeper-chat-event-timeline.md`](../../design/keeper-chat-event-timeline.md).
Antigravity's nonempty step text is currently forwarded before classifying step
type; the document already calls out the unknown meaning of Internal, Tool and
Unrecognized text. This audit did not count those documented limits again as
new bugs without an authoritative payload counterexample.

## Count and evidence boundary

- Additional independently confirmed provider/adapter P0-P2 findings: **0**.
- Confirmed source evidence added to an existing cross-domain ordering finding: **1**.
- No claim of complete protocol conformance, executed regression coverage or
  production reproduction follows from this source review.

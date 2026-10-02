# Chat streaming continuity audit

Scope: TUI new input, queue admission, batch binding, journal replay, runtime retry/checkpoint, settlement, and all Keeper runtime text paths present in source. Evidence is source inspection and syntax parsing, not provider calls or production proof.

## Findings and fixes

| Boundary | Failure | Correction | Regression |
| --- | --- | --- | --- |
| New TUI request | New msg_live hid older inflight text/tools | Retain other request-owned logs | test_new_input_preserves_running_output |
| Autonomous preview | Working chat suppressed unrelated autonomous output | Suppress duplicate preview only for chat-operation lane | Same rendered-frame test |
| Batch subscriber lag / completion | Partial follower hid richer/complete execution output | Choose complete log, then greatest journal sequence, stable ties | Same test with Batch_bound and older completion |
| Claude Code CLI | No partial-messages flag; only complete blocks forwarded | Enable documented partial SDK frames; emit text immediately; reconcile complete block suffix | test_partial_text_streams_before_complete_block |
| Codex app-server | Completed item missing some/all deltas was silent until turn end | Emit missing suffix at item/completed | Existing tool-order tests plus test_completed_message_streams_without_delta |
| Codex optional identities | Named/unnamed delta and anonymous completion could contaminate next item | Bind active anonymous prefix; close effective identity at completion | test_mixed_item_identity_keeps_delta_order and test_anonymous_completion_closes_current_item |
| Antigravity | Partial step output prevented final missing suffix from reaching Keeper stream | Flush shared text-stream remainder at Turn_finished | test_keeper_preserves_final_suffix_after_partial_steps |

## Inspected runtime paths

| Runtime / provider | Source path | Result of source inspection |
| --- | --- | --- |
| Codex app-server | lib/runtime/runtime_codex_app_server.ml; lib/keeper/keeper_codex_runtime.ml | Deltas forwarded; completion-suffix correction above |
| Claude Code | lib/runtime/runtime_claude_code.ml; lib/keeper/keeper_claude_code_runtime.ml | Partial-text correction above; complete blocks retain terminal text/usage/native-tool ownership |
| Antigravity | lib/runtime/runtime_antigravity.ml; lib/keeper/keeper_antigravity_runtime.ml | Step deltas forwarded; final-suffix correction above |
| Muse | lib/keeper/keeper_muse_runtime.ml, stream_projection | Already reconciles Text_completed and final remainder; no additional concrete loss found |
| Anthropic HTTP | packages/agent_core/lib/llm_provider/complete_stream.ml, Anthropic_messages | SSE events projected and immediately delivered through dispatch; no additional concrete loss found |
| OpenAI compatible, GLM, Kimi | Same transport; openai/Responses streaming codecs | SSE events normalized before callback; terminal stream integrity checks present |
| Gemini HTTP | Same transport, Gemini_generate_content | Chunk events projected through dispatch; typed unsupported/parse failures retained |
| Ollama HTTP | Same transport, Ollama_chat | NDJSON reader dispatches each line; done/stop-reason integrity checks present |
| Shared Agent Core runtime | lib/runtime/runtime_agent.ml | New input, checkpoint continuation and cooperative tool-boundary paths choose Stream when on_event exists; declared unsupported native streaming deliberately chooses Sync |

## Shared lifecycle inspection

- New requests retain previous msg_inflight; submission target is None, so Enter does not request interruption.
- SSE replay registers the live sink before journal replay, queues overlapping frames, and drops replayed sequence identities.
- TUI reconnect retains the request log, resets only the decoder, and reuses operation ID plus the latest delivered journal position.
- Journal-follow reads, rather than out-of-order observer frames, feed observed logs.
- Retry boundaries retain prior trail nodes as superseded attempts. Checkpoint segment restart clears current text/thinking buffers while retaining prior trail nodes.
- Received deltas update transcript revisions; observed journal replacement changes settled-list identity for chat row memoization.
- Redaction flushes held content at message/attempt boundaries and completion.

## Verification limits

Syntax parsing and whitespace checks pass for touched OCaml files. Regression executables, type checks, real provider calls and actual TUI screenshots have not run. The repository prohibits external-session local Dune builds; this report does not reinterpret source review as runtime proof. No server/TUI restart or installation was performed. Local CLI checks: Claude Code 2.1.287 advertises --include-partial-messages; Codex CLI 0.160.0. These are host CLI observations, not proof of sandbox provider behavior.

Batch representative selection relies on ordered per-member journal delivery; highest seq is a replay position, not independent proof of contiguous coverage. Unknown model capabilities can intentionally disable native streaming. This is not a promise that every model streams.

## Current official protocol evidence

[Evidence] Claude token streaming requires include-partial-messages, wraps API events in stream_event, and sends each completed assistant block before content_block_stop: https://code.claude.com/docs/en/headless and https://code.claude.com/docs/en/agent-sdk/streaming-output. Checked 2026-10-02T12:01:05+09:00; confidence High. Codex completed items finalize earlier message delta output: https://openai.com/index/unlocking-the-codex-harness/ and https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs. Checked 2026-10-02T12:01:05+09:00; confidence High.

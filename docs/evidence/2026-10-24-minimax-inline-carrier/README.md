# Exact scalar MiniMax Chat content replay

The [official MiniMax OpenAI SDK contract](https://platform.minimax.io/docs/api-reference/text-openai-api), reread 2026-10-24, requires complete preservation of inline `<think>` content and separately returned reasoning fields. The [tool/interleaved guide](https://platform.minimax.io/docs/guides/text-m3-function-call) requires returning the full assistant response even when thinking is absent. The prior [executed inline gap](../2026-10-24-minimax-inline-replay-gap/README.md) showed sync/SSE parsing moving original inline content into a sidechannel on replay. Its original failing output remains historical evidence; this change does not relabel it as a passing current consumer run.

## Production change

The native `minimax-m3` catalog row now declares `think_tags_with_chat_replay`; its existing prefix matching includes its M3 family suffixes. Parse-only `think_tags` declarations retain their previous behavior. This does not opt in Ollama-hosted MiniMax, M2 rows, tool_choice acceptance or Responses parity.

`Inline_content_replay` retains the original scalar content and exact canonical occurrence indices. Validation re-splits the original bytes and compares the bound Text/Thinking sequence; all visible Text must be covered, while independent native reasoning and tools can remain unbound. Appended/edited visible text, invalid/duplicate indices, signed inline blocks and malformed/duplicate metadata fail validation. A replay carrier is never reconstructed by joining Thinking and inventing tags.

Sync parsing captures this witness in telemetry. Chat SSE captures original content deltas transactionally, including explicit empty strings; absent/null content creates no scalar witness. One terminal event names the emitted stream block identities, and the pure accumulator validates and maps them into canonical content coordinates. The synthetic stream path preserves the witness too. Telemetry/cache JSON and canonical assistant metadata retain it. Keeper event consumers treat the internal witness as protocol data and never display its raw thinking.

Reasoning projection validates the witness before source/control lowering, remaps indices after exclusions, and removes the complete carrier if any required piece is removed or source/replay policy excludes it. The matching declared Chat serializer restores original content while separately returned reasoning retains its own field. Tool admission uses the same pure response-retention function to remap both Responses grouping and inline witnesses after rejecting an interleaved tool. It does not infer identity from matching text or tool IDs.

The resolved immutable reasoning dialect and persisted replay contract now include `content_carrier` (`Canonical_blocks` or `Inline_chat_content`). `replay_contract` remains a complete field projection. Stable producer and effective consumer agree; non-Chat envelopes select canonical carriers. The serialized field is required: previous source/cache artifacts lacking it are invalid or cache misses, with no conversion/default. This is a deliberate source-schema hard cut affecting historical stamps across providers. Endpoint rotation policy is unchanged. Checkpoint resume guarantees remain separate #27894 work.

## Executed isolated source proof

```sh
python3 docs/evidence/2026-10-24-minimax-inline-carrier/run_fixture.py
```

The runner compiles the actual extracted `Inline_content_replay` module, actual production splitter core (excluding its inline tests), and the unchanged replay-contract module/interface with their real deriving codecs. `result.json` records source hashes and 21 passing assertions. They cover raw bytes, metadata JSON, independent reasoning, index remapping, partial drop, uncovered/edited content, malformed occurrences, every tag/UTF-8 chunk cut at the splitter boundary, empty/unfinished tags, required carrier decoding and semantic identity.

Content payload types in the isolated carrier compilation are fixture types. The runner does not execute the production sync parser, Chat serializer, SSE projector, accumulator, tool admission or whole project. It does not build/link Core/MASC or contact a provider. Its splitter byte-cut cases are parser fragments, not claims that invalid UTF-8 can occur inside a JSON SSE event.

## Production consumer fixture source

`test_backend_openai_codec.ml` extends the shipped native catalog → sync/SSE parser → cache JSON → canonical assistant history → final request path with inline-only, mixed/multiple segments, whitespace/Unicode, unfinished/empty tags and inline plus independent native reasoning. ASCII SSE inputs use one-character deltas; Unicode deltas remain valid UTF-8. The fixture requires exact original content and reasoning/tool fields after a later human query, distinguishes null from empty content, and checks incompatible-model exclusion. Separate source cases exercise synthetic events, malformed witnesses, partial reasoning exclusion and actual tool admission rejecting an interleaved unknown tool followed by witness remapping.

These production consumer tests have **not been executed or typechecked** in this external coding session. Syntax checks, isolated module execution and source review do not establish consumer success. No Dune, full project build, CI, provider HTTP, installation or runtime/UI proof is claimed. #27924 remains open pending the broader conformance acceptance and integration evidence.

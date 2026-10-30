# Native turn-scoped context and signed creation prefixes

The native Messages [mid-conversation System contract](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages) accepts text System groups after a user span and before an assistant or request end. Its `clear_at: next_user_message` contract requires `mid-conversation-system-clear-at-2026-08-21`. A tool-result User also clears the preceding context. The [preserved-thinking contract](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking) explicitly documents keeping prior cleared messages verbatim to preserve later signed prefixes for Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5. Those four catalog rows explicitly opt into `turn_scoped_system_context_preserve_always`; no model-name or text-prefix inference occurs in consumers.

Current and historical typed context encode identically as `role: system`, `clear_at: next_user_message`, with unchanged content at their original position. Historical context is neither hoisted nor quoted. Canonical source messages remain unchanged. Scoped content must be nonempty and text only; it receives no cache marker. Placement is checked before reasoning projection and again on the exact transcript after followup merging and prefix filtering. This second check matters when a reasoning-only assistant disappears and leaves a System directly before a User.

The native serializer and creation-prefix fold share one header encoder, including both role and clear_at. Removed empty assistants contribute no phantom header to the digest. Prefix stamps use `agent_core.reasoning_prefix.v2`; old stamps are absent certification, with no conversion or migration. This does not establish resumed artifact compatibility (#27894). Sync, streaming and exact-output transports already use the shared body-sensitive beta resolver; Count_tokens now uses it too.

Ordinary User, Recovery_instruction and Agent_instruction retain their existing continuation placement in this layer. An instruction after an assistant cannot become a text System there under the native rules. No human query, tool ID or server-tool-result support is fabricated. #27904 was closed remotely after the preceding layers merged. This PR still tracks the native context repair; other origin/episode paths and integration evidence remain outside its verified scope. Issue closure does not establish those execution results.

## Executed isolated source evidence

```sh
python3 docs/evidence/2026-10-24-anthropic-context-origin/run_fixture.py
```

The runner compiles the unchanged production lowerer and its interface with a namespace open, and extracts the actual production prefix verifier, prefix metadata decoder and beta resolver from named source boundaries. It executes 24 assertions recorded in result.json, which includes source and extraction hashes. Assertions cover fresh/historical wire equality, source coordinates, immutable canonical values, signed-prefix self-consistency across a client tool loop, text/header tampering, stamp hard cut, removed-assistant hashing, post-filter placement, unsupported content/placement/codecs, and beta composition without a thinking object. The prior Qwen reproduction also passes again with the new enum fixture dependency and current lowerer.

Dependencies are deliberately isolated: Types/content payloads, config/capabilities, source classifier, UTF-8 sanitizer and response-replay metadata retention are fixture implementations. The fixture encoder is not the production serializer. Synthetic signatures are only bytes for the local prefix self-check; no provider signature authentication occurs. The script does not link MASC/Core, run the full reasoning projector or count-token HTTP transport, contact a provider, or prove server rendering, token counts or signature acceptance. No Dune, project typecheck, CI, installation or UI verification is claimed.

## Production consumer fixture source

Two added Alcotest cases call the production native request builder, producer stamp, retained-prefix observer and Count_tokens builder. They cover a stamped thinking/tool-use response, current-to-historical context, tool-result continuation, fresh context, edited-prefix rejection, context placement after a dropped assistant, canonical immutability, cache-marker exclusion and beta merging. They are source fixtures and were not executed. Parser checks do not establish their type correctness or success.

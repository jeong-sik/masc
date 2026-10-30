# Reasoning and public answer boundary

The product invariant is that provider reasoning never becomes user speech.
This belongs to the common Connector/Channel/Gate boundary and UI projections,
not separate Slack or Discord cleanup. Diagnostic reasoning remains distinct
from public answer text. Terminal canonical replacement remains necessary, but
cannot retract a public delta already observed by a user.

## Evidence and scope (2026-09-10)

Official contracts separate channels:
- Ollama: https://docs.ollama.com/capabilities/thinking — message.thinking versus message.content.
- Z.AI: https://docs.z.ai/guides/capabilities/thinking-mode — reasoning_content versus content; preserved reasoning requires original order.

Upstream issue reports are reproduction evidence, not universal contracts:
- https://github.com/ollama/ollama/issues/18082 reports orphan closing tags for GLM cloud on Ollama 0.32.14, including native and compatible endpoints. Opening-tag-only consumers cannot prevent this case.
- https://github.com/ollama/ollama/issues/18009 reports retained suffix loss on terminal flush at commit e2c6c7e8.
- https://github.com/ollama/ollama/issues/11010 records older think=false behavior; it does not prove current deployments reproduce it.

MASC history:
- #32840 measured MiniMax native reasoning_details plus inline tags and intentionally made the channels orthogonal. That evidence does not authorize generic splitting of every reasoning-capable model.
- #34159 restored the documented GLM-4.6V delta:reasoning_content declaration in provider scope; catalog tests were not live-wire proof.
- #34698 projected official-client envelopes for TUI; canonical JSON encoding is currently assumed by its prefix recognizer. Equivalent reserialization is a remaining conditional UI gap.

The source audit at #34896 head 8ae765291 found:
1. Native Ollama sync did not apply the inline framing contract.
2. Template_parser implicitly enabled streaming-only tag parsing, disagreeing with sync and the orthogonal contract.
3. The splitter combined text/reasoning into two strings and reordered interleaved segments depending on network chunking.
4. Native reasoning_details and inline ThinkingDelta shared a block identity.
5. The Keeper bridge retained non-tool occupancy but not public/reasoning channel type; a mismatched TextDelta could become public speech.
6. A preliminary public delta is replaced by final Reply_details in TUI and Dashboard. This explains the reported flicker if reasoning was misclassified upstream; no live-browser reproduction has yet established the user's exact runtime path.

## This change

- Only explicitly declared content_inline_reasoning enables tag framing; native dialect is independent.
- Sync Ollama and compatible responses use the same ordered splitter.
- Inline segments retain order and separate block identity from native reasoning.
- Declared reasoning blocks reject public text deltas at the common Keeper bridge.
- Parser/stream/bridge fixture sources cover partitioned tags, typed separation and incremental public answer delivery.

## Acceptance still required

Test each currently supported provider/runtime/version, not every historical model.
For each delta, public text contains only answer bytes; answer fragments appear
before MessageStop; final canonical answer matches the streamed answer. Reasoning
is absent from public UI/Connector speech throughout, not only in the final frame.
Keep raw wire, request/runtime identity, event sequence and browser evidence.

Close-only or unframed ambiguous content is NOT repaired by guessing prose or
looking for semantic keywords. A runtime known to emit that unsupported format
cannot be certified by these paired-tag fixes. Establish its current wire contract,
fix or upgrade the producer, or exclude that runtime from supported public output.
No provider-specific initial-state recovery or text-equality deduplication is added.
Native and inline reasoning may both exist; no inferred alias identity is assumed.

Status: source/parse/diff checks only. No local build, live-provider acceptance,
UI screenshot or full leakage-free claim. Kimi calls remain paused at operator
request due to rate limiting. The generic corpus and UI acceptance remain separate
follow-up work; do not mark the overall bug complete from green CI alone.

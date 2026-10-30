# Reported OpenAI-compatible stream metadata

GLM's parser already retains each chunk's response `id` and `model`. The shared
OpenAI-compatible projector now publishes the first complete, nonblank pair as
one `MessageStart`, before the response's other normalized events. It never
substitutes the requested model or builds a pair from separate partial chunks.
The same behavior applies to OpenAI Chat, GLM and other clients of this projector;
Responses, Gemini and Ollama NDJSON keep their existing event paths.

## Prelude window and admission

One sequential HTTP response owns the normalization state. Its typed prelude
state is awaiting metadata, reported prelude published, or output without a
prelude. A metadata-poor chunk keeps its existing admission and content behavior:

- An empty or partial prelude that emits no events leaves the window open.
- The first complete pair publishes a start, even on a role-only prelude.
- Content, tool headers, usage or a terminal event published without a complete
  pair closes that window. Later metadata cannot start a second response.
- Repeated or changed metadata after the first start does not alter admission,
  erase output or create another start. A new HTTP request owns a fresh state,
  even when the provider reuses the same response ID.
- A rejected tool chunk publishes only the existing typed failure and rolls
  back its state. Neither a reported prelude nor an absent-prelude decision
  from its discarded content leaks to a subsequent projection.

Usage stays on the existing `MessageDelta`, not a second copy on the start.
A reported start is neither a generated token nor evidence of Thinking.
The complete-stream accumulator therefore receives metadata before blocks,
and Keeper's existing stream scope, rather than the provider ID alone,
continues to identify the response occurrence.

This is a bounded metadata observation repair. Metadata arriving only after
output is deliberately unreported. Preserving such updates would require a
separate metadata event whose semantics cannot reset lifecycle or content;
this change does not add that contract.

## Provider evidence

The [Z.AI streaming guide](https://docs.z.ai/guides/capabilities/streaming)
shows the response ID and model from the first content chunk through completion.
The [OpenAI chunk reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)
identifies the response with a common ID across its chunks and includes the model.

The [llama.cpp Chat serializer](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/server-task.cpp)
adds ID and model to normal and prompt-progress chunks. The existing repository
fixture captures this shape from llama-server b10180. Its newly visible prelude
still has no content and does not count as first-token progress.

[OpenRouter's streaming guide](https://openrouter.ai/docs/api/reference/streaming)
distinguishes SSE comments and a final accounting chunk. Comments remain in the
existing transport parser, and accounting data remains on its usage path.
[MiniMax's OpenAI SDK guide](https://platform.minimax.io/docs/api-reference/text-openai-api)
documents streaming text/reasoning and optional usage but does not establish a
mandatory ID/model pair on every wire frame. These sources do not justify
rejecting all metadata-poor chunks accepted by the shared projector.

## Verification scope

Focused fixtures retain existing content, tool identity, reasoning dialect and
transactional rollback assertions while explicitly checking the added prelude.
They cover partial/empty preludes, first content with metadata, later changed
metadata, missing metadata followed by late metadata, preserved earlier usage,
usage-only tails after tool-only responses, repeated IDs in separate requests,
and the terminal sentinel. A GLM parser-to-accumulator fixture checks reported
metadata before reasoning; the existing HTTP fixture checks `Connected`, then
the reported start, then Text while retaining timing assertions.

Syntax parsing and source review do not establish type checking, executed
fixtures, provider-live behavior or a rendered TUI. No build or runtime test was
performed for this source-only author unit.

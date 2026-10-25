# MiniMax Responses contract and current decoder boundary

Relates #27924. Official index and schemas were read on 2026-10-25.
Source audit: main `8d872e10305f4ce1fc7e14c47379d462c184da20`.
`contract-snapshot.json` retains the selected schema nodes, original full-document
SHA256/byte lengths, source-file hashes and observation time. The source
OpenAPI documents declare MIT licensing. This is a source/schema comparison;
no production codec executable or MiniMax HTTP request was run for this audit.

## Confirmed official boundaries

The [official index](https://platform.minimax.io/docs/llms.txt) links
[Responses OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-responses.json).
Its POST `/v1/responses` request schema lists `tool_choice` as the singleton
`auto`. This is positive documentation of that Responses contract, not a
measurement that the endpoint rejects other values. It does not establish a
Chat or Anthropic restriction. The separately read
[Chat schema](https://platform.minimax.io/docs/api-reference/text/api/openapi-chat-openai.json)
does not list `tool_choice`; absence alone proves neither acceptance nor rejection.
No capability or request-builder policy is changed here.

Responses input admits message, function_call, function_call_output and
reasoning items. Reasoning input describes summary/summary_text; reasoning
output has both summary and content/reasoning_text. The official deep-thinking
example has an empty summary and nonempty content. The output-to-input shape
therefore needs explicit conformance work; compatibility branding is insufficient.

The request schema does not list previous_response_id or store. A response
example contains previous_response_id:null and store:false. Those example
fields do not establish request support, retained server history or universal
rejection. Model-specific reasoning controls also differ: M3.1-Flash is always
on; M3 reasoning defaults off on Responses, while its Chat contract defaults on.
Do not copy Chat controls or a schema-wide effort enum into every model.

## Current source gap and next executable proof

`backend_openai_responses.ml` reads encrypted_content first, then only summary
for a reasoning output item (`content_blocks_of_reasoning_item`). For the
documented empty-summary/nonempty-content example, that function yields no
Thinking block and the grouping loop omits the empty reasoning group. This is
a direct source deduction, not an executed failure or a report about all
MiniMax runtime requests. Native MiniMax Responses activation is not claimed.

The streaming decoder already handles response.reasoning_text.delta and done.
Thus the sync omission does not prove every SSE path loses reasoning. Inspect
item-done/terminal-only and delta-to-terminal reconciliation separately.
The outgoing Thinking projection emits summary_text, matching the documented
input carrier; preserve item ordering, source identity and tool-call IDs while
establishing the correct output-content to input-summary mapping.

Next implementation must exercise the public parse → persisted canonical
history → request path with the official output shape, including tool call and
function result, a later user turn, sync/SSE equivalence, and terminal-only
recovery. Retain original OpenAI encrypted/summary behavior. Declare any
provider/protocol distinction through typed immutable contracts rather than
model-name checks. Establish source-backed MiniMax Responses binding before
claiming production activation; document the supported tool policy independently.

## Existing work stays distinct

The inline Chat carrier repair #45772 is merged. PR #45859 adds native family
activation and structured replay; its actual 121-case result at
`64c63aeb3f649d2539ef394aeafd93f4c4a27f5d` remains the earlier Chat execution.
It is not a Responses result. This audit neither reruns nor extends that receipt.
No live-provider, installed runtime, full regression, approval, merge or whole
issue completion is established. #27924 remains open.

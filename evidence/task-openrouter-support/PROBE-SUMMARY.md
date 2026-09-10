# OpenRouter Live Probe — Ground-Truth Evidence

Date: 2026-09-10. All probes executed live against `https://openrouter.ai/api/v1/chat/completions`
with the account key from `OPENROUTER_API_KEY`. Every case below returned **HTTP 200** on the
first attempt — no retries were needed and no error bodies were observed.
The `basic` case also sent `HTTP-Referer: https://github.com/jeong-sik/masc` and `X-Title: MASC`
headers for every model; all were accepted without error.

Spend across probe rounds 1-2 was ~$0.0058 on a paid (non-free-tier) key. The
key-info response is deliberately not archived here: it carries an account id
and a masked key prefix, neither of which any claim below rests on.

## Per-model results

| model (OpenRouter id) | basic | stream | tool_calls | reasoning-field | usage-present | notes (errors) |
|---|---|---|---|---|---|---|
| deepseek-flash (`deepseek/deepseek-v4-flash`) | 200, content `"OK"`, finish `stop` — `probe-deepseek-flash-basic.json` | SSE ok, 9 chunks + `[DONE]`, finish `length` (16-token budget eaten by reasoning) — `probe-deepseek-flash-stream.json` | yes: `get_weather({"city": "Seoul"})`, finish `tool_calls` — `probe-deepseek-flash-toolcall.json` | `message.reasoning` (string) + `reasoning_details[]` type `reasoning.text` — `probe-deepseek-flash-reasoning.json` | yes: non-stream `usage` obj; stream final chunk carries `usage` | none |
| claude-sonnet (`anthropic/claude-sonnet-5`) | 200, content `"OK"`, finish `stop` — `probe-claude-sonnet-basic.json` | SSE ok, 4 chunks + `[DONE]`, finish `stop` — `probe-claude-sonnet-stream.json` | yes: `get_weather({"city": "Seoul"})`, finish `tool_calls` — `probe-claude-sonnet-toolcall.json` | `message.reasoning` (string) + `reasoning_details[]` type `reasoning.text` (with `signature`) — `probe-claude-sonnet-reasoning.json` | yes: non-stream + stream final chunk | none |
| gpt55 (`openai/gpt-5.5`) | 200, content `"OK"`, finish `length` (10 of 16 tokens were reasoning) — `probe-gpt55-basic.json` | SSE ok, 4 chunks + `[DONE]`, finish `length` — `probe-gpt55-stream.json` | yes: `get_weather({"city":"Seoul"})`, finish `tool_calls` — `probe-gpt55-toolcall.json` | **none readable**: `reasoning: null`; `reasoning_details[0]` type `reasoning.encrypted` (opaque `data`, 1532 chars, `id: rs_...`, format `openai-responses-v1`) — `probe-gpt55-reasoning.json` | yes: non-stream + stream final chunk | none |
| glm53 (`z-ai/glm-5.3`) | 200, content `"OK"`, finish `stop` — `probe-glm53-basic.json` | SSE ok, 6 chunks + `[DONE]`, finish `length` (reasoning consumed budget); reasoning streamed in `delta.reasoning` — `probe-glm53-stream.json` | yes: `get_weather({"city":"Seoul"})`, finish `tool_calls` — `probe-glm53-toolcall.json` | `message.reasoning` (string, e.g. `"17*23 = 391."`) + `reasoning_details[]` type `reasoning.text` — `probe-glm53-reasoning.json` | yes: non-stream + stream final chunk | none |
| gemini-flash (`google/gemini-3.8-flash`) | 200 but **content `null`**, finish `length` — all 12 completion tokens were reasoning — `probe-gemini-flash-basic.json` | SSE ok, 4 chunks + `[DONE]`, finish `length`; reasoning streamed in `delta.reasoning` — `probe-gemini-flash-stream.json` | yes: `get_weather({"city":"Seoul"})`, finish `tool_calls` — `probe-gemini-flash-toolcall.json` | **empty in this response**: `reasoning: null`; `reasoning_details[0]` type `reasoning.text` with `text: ""` and a `signature` (format `google-gemini-v1`); 80 reasoning tokens billed. In the basic case the same fields DID carry readable text (349 chars) — inconsistent — `probe-gemini-flash-reasoning.json` | yes: non-stream + stream final chunk | none |
| kimi-k3 (`moonshotai/kimi-k3`) | 200 but **content `null`**, finish `length` — all 16 tokens were reasoning — `probe-kimi-k3-basic.json` | SSE ok, 6 chunks + `[DONE]`, finish `length`; reasoning streamed in `delta.reasoning` — `probe-kimi-k3-stream.json` | yes: `get_weather({"city": "Seoul"})`, finish `tool_calls` — `probe-kimi-k3-toolcall.json` | `message.reasoning` (string, `"17*23 = 391."`) + `reasoning_details[]` type `reasoning.text` — `probe-kimi-k3-reasoning.json` | yes: non-stream + stream final chunk | none |

## Cross-model facts (measured)

- **Reasoning field name**: OpenRouter normalizes readable reasoning to `message.reasoning`
  (string) with a mirrored `message.reasoning_details[]` array (`type: reasoning.text`).
  Observed for deepseek-v4-flash, claude-sonnet-5, glm-5.3, kimi-k3. No model used
  `reasoning_content` (the DeepSeek-official-API field name) — OpenRouter always emitted
  `reasoning`. In streaming, deltas carry `delta.reasoning` (+ `delta.reasoning_details`).
- **Encrypted/opaque reasoning**: gpt-5.5 returns only `reasoning.encrypted` entries
  (opaque `data` blob + `rs_...` id, format `openai-responses-v1`) — no readable text.
  gemini-3.8-flash attaches a `signature` (format `google-gemini-v1`); its readable text
  was present in one probe and empty in another, so treat text as optional, signature as
  the stable artifact.
- **Reasoning models burn the completion budget**: with `max_tokens: 16`, deepseek-flash /
  gpt55 / glm53 / gemini-flash / kimi-k3 finished with `finish_reason: "length"` on the
  trivial "Reply with exactly: OK" prompt; gemini-flash and kimi-k3 returned
  `content: null` because reasoning consumed the entire budget. claude-sonnet-5 was the
  only one to answer within 16 tokens (`stop`). Small `max_tokens` is unsafe for
  reasoning models.
- **Tool calls**: all 6 models honored `tool_choice: "required"` and returned
  `message.tool_calls[0].function.name = "get_weather"` with `arguments` a JSON string
  containing `city: "Seoul"`, `finish_reason: "tool_calls"`.
- **Streaming**: all 6 streamed SSE `chat.completion.chunk` objects terminated by
  `data: [DONE]`. For every model the **final data chunk before `[DONE]` carried a full
  `usage` object** (same chunk as `finish_reason`) without sending `stream_options`.
- **Usage/cost fields**: every non-stream response included `usage` with OpenRouter
  extensions: `cost` (USD), `is_byok`, `prompt_tokens_details`, `cost_details`,
  `completion_tokens_details.reasoning_tokens`.
- **Headers**: `HTTP-Referer` and `X-Title` accepted (HTTP 200) on all 6 models.
- **Errors**: none observed. All 25 artifacts (24 case responses + key info) are HTTP 200
  bodies; no retries were performed.

## Probe round 2

Date: 2026-09-10. Six additional models, two cases each: `basic` (`max_tokens: 64`,
"Reply with exactly: OK") and `toolcall` (`tool_choice: "required"`, `max_tokens: 512`).
All `basic` probes returned HTTP 200 on the first attempt with content `"OK"` and
`finish_reason: "stop"` — no budget-exhaustion retries were needed at 64 tokens, even for
the reasoning models.

| model (OpenRouter id) | basic | tool_choice_required | notes |
|---|---|---|---|
| claude-opus (`anthropic/claude-opus-5`) | 200, content `"OK"`, finish `stop`, 4 completion tokens, no reasoning — `probe2-claude-opus-basic.json` | yes: `get_weather({"city": "Seoul"})`, finish `tool_calls` — `probe2-claude-opus-toolcall.json` | none |
| gpt56-sol (`openai/gpt-5.6-sol`) | 200, content `"OK"`, finish `stop`, 5 completion tokens, 0 reasoning tokens — `probe2-gpt56-sol-basic.json` | yes: `get_weather({"city":"Seoul"})`, finish `tool_calls` — `probe2-gpt56-sol-toolcall.json` | unlike gpt-5.5 in round 1, burned no reasoning budget on the basic prompt |
| glm53-flash (`z-ai/glm-5.3-flash`) | 200, content `"OK"`, finish `stop`, 30 completion tokens (27 reasoning) — `probe2-glm53-flash-basic.json` | yes: `get_weather({"city":"Seoul"})`, finish `tool_calls` — `probe2-glm53-flash-toolcall.json` | cheapest probe of the round (~$0.000018) |
| grok46 (`x-ai/grok-4.6`) | 200, content `"OK"`, finish `stop`, 124 completion tokens (123 reasoning) — `probe2-grok46-basic.json` | yes: `get_weather({"city":"Seoul"})`, finish `tool_calls` — `probe2-grok46-toolcall.json` | heaviest reasoning burn on a trivial prompt; most expensive basic probe (~$0.00097) |
| qwen38-max (`qwen/qwen3.8-max-0902`) | 200, content `"OK"`, finish `stop`, 23 completion tokens (19 reasoning) — `probe2-qwen38-max-basic.json` | **HTTP 400**: provider Alibaba rejects the request — `invalid_parameter_error`: "The tool_choice parameter does not support being set to required or object in thinking mode" — `probe2-qwen38-max-toolcall.json` | thinking-mode limitation: `tool_choice: "required"` is not accepted; verbatim error body saved in artifact; no retry (deterministic provider constraint) |
| deepseek-pro (`deepseek/deepseek-v4-pro`) | 200, content `"OK"`, finish `stop`, 28 completion tokens (25 reasoning) — `probe2-deepseek-pro-basic.json` | yes: `get_weather({"city": "Seoul"})`, finish `tool_calls` — `probe2-deepseek-pro-toolcall.json` | none |

Round-2 facts (measured):

- 5 of 6 models honored `tool_choice: "required"` with `finish_reason: "tool_calls"` and
  JSON `arguments` containing `city: "Seoul"`. The exception is qwen38-max, whose
  provider (Alibaba) rejects `required`/object tool_choice in thinking mode (HTTP 400).
- At `max_tokens: 64` every model — including the four reasoning models — answered the
  trivial prompt with `stop`; the round-1 `length`/`content: null` failures were at
  16 tokens. Reasoning burn on "Reply with exactly: OK" ranged from 0 tokens
  (claude-opus, gpt56-sol) to 123 tokens (grok46).
- All round-2 responses included the OpenRouter `usage` extensions (`cost`, `is_byok`,
  `cost_details`, `completion_tokens_details.reasoning_tokens`).

## Probe rounds 3-5 — request shape and reasoning replay

Date: 2026-09-10, same account key. These rounds answered two questions the
first two rounds left open: which request parameter actually turns reasoning
on, and whether a prior turn's reasoning item may be replayed.

### Which parameter yields reasoning (round 4)

`probe4-<model>-<param>.json`, prompt "What is 17*23? Think it through, then
give the number.", `max_tokens: 400`.

| model | `reasoning_effort: high` | `include_reasoning: true` | `reasoning: {effort: high}` |
|---|---|---|---|
| `openai/gpt-5.5` | text + `[reasoning.summary, reasoning.encrypted]`, 31 reasoning tokens | text + same two details, 46 tokens | text + same two details, 44 tokens |
| `deepseek/deepseek-v4-flash` | text + `[reasoning.text]`, 65 tokens | **nothing**: `reasoning: null`, no details, 0 reasoning tokens | text + `[reasoning.text]`, 37 tokens |

`reasoning_effort` is what masc's `reasoning_effort` thinking dialect already
emits, and it is sufficient on both models. `include_reasoning` alone is not:
deepseek-v4-flash did no thinking at all under it.

An earlier attempt (`probe3-t1-toolcall.json`) saw no reasoning on a
`tool_choice: required` turn. That was the model spending 0 reasoning tokens on
that particular turn, not a missing contract — the same model reasons when the
prompt calls for it.

### Reasoning replay (round 5)

`probe5-*.json`, `openai/gpt-5.5`, `reasoning_effort: high`, a `multiply` tool
and the prompt "Decide carefully whether you need the multiply tool for
4177 * 3391, then use it."

| case | result |
|---|---|
| `t1` — first turn | HTTP 200, tool call issued, message carries `[reasoning.summary, reasoning.encrypted]` |
| `t2-with-encrypted-replay` — history replays `reasoning` + `reasoning_details` on the assistant turn | HTTP 200, answered `4177 × 3391 = 14,164,207` |
| `t2-stripped` — same history with the reasoning item removed | HTTP 200, same answer |

So replaying the encrypted item is **accepted** and is **not required**. The
catalog rows declare `reasoning_replay = "drop_without_tool"` on that basis:
it keeps an encrypted chain intact across a tool call, and omitting it would
not have failed the request, only restarted the model's reasoning.

### What this evidence changed in the code

- `reasoning_streaming_format` gained `delta_details:<field>`. The existing
  axis could read either a named text delta **or** `reasoning_details` (under
  a hardcoded `reasoning_content`), never both. gpt-5.5's stream carries
  `delta.reasoning = null` beside a `reasoning.encrypted` item
  (`probe-gpt55-stream.json`), so the text-only reading dropped the item
  entirely.
- All twelve OpenRouter catalog rows declare `delta_details:reasoning`,
  `split_reasoning_fields` and `drop_without_tool`.
- `qwen/qwen3.8-max-0902` declares `supports_required_tool_choice = false` and
  `supports_named_tool_choice = false`, from the HTTP 400 in round 2.

### The extra request field `split_reasoning_fields` causes (round 6)

Declaring `reasoning_output_format = "split_reasoning_fields"` is what makes
masc replay `reasoning_details` on assistant turns, but the same axis also puts
`"reasoning_split": true` on the request whenever thinking is on
(`reasoning_dialect.ml`, `reasoning_output_fields`). OpenRouter lists that
parameter in no model's `supported_parameters`, so it was probed rather than
assumed — including the two vendors that were strictest elsewhere (Alibaba
rejected `tool_choice: required` in round 2; Anthropic omits `seed`).

`probe6-<model>-reasoning-split.json`, `reasoning_effort: high` plus
`reasoning_split: true`, prompt "What is 17*23? Answer with the number."

| model | result |
|---|---|
| `openai/gpt-5.5` | HTTP 200, content `391` |
| `deepseek/deepseek-v4-flash` | HTTP 200, content `391` |
| `qwen/qwen3.8-max-0902` | HTTP 200, content `391` |
| `anthropic/claude-opus-5` | HTTP 200, content `**391**` |

The gateway drops the unknown parameter, as its documentation says it does.
`split_reasoning_fields` is therefore safe to declare on these rows.

### The reasoning_effort ladder, rung by rung (round 7)

`accepted_reasoning_efforts` is not decoration on this wire. With it absent,
`Provider_config.validate_reasoning_effort_request` answers
`Undeclared_reasoning_effort_capability` and `build_request_assoc` turns that
into `Invalid_argument` — every thinking turn raises. A local test caught
exactly that before this landed. So each rung was probed rather than assumed:
12 models x 7 rungs, `probe7-<model>-effort-<rung>.json`,
prompt "What is 17*23? Answer with the number.", `max_tokens: 200`.

Every model accepted `minimal`, `low`, `medium`, `high`, `xhigh` and `max`.
The rungs split only on the disable rung:

| `reasoning_effort: "none"` | models |
|---|---|
| **HTTP 400** — "Reasoning is mandatory for this endpoint and cannot be disabled" | `google/gemini-3.8-flash`, `x-ai/grok-4.6`, `z-ai/glm-5.3`, `z-ai/glm-5.3-flash`, `qwen/qwen3.8-max-0902` |
| HTTP 200 with 0 reasoning tokens billed | `openai/gpt-5.5`, `openai/gpt-5.6-sol`, `anthropic/claude-opus-5`, `anthropic/claude-sonnet-5`, `deepseek/deepseek-v4-flash`, `deepseek/deepseek-v4-pro`, `moonshotai/kimi-k3` |

For the seven that take it, `none` is a real disable and not merely accepted:
`completion_tokens_details.reasoning_tokens` came back 0. The five that refuse
it declare a ladder without the rung, which is the shape
`Explicit_disable_outside_ladder` already exists to describe — ladders without
`none` are common in the catalog.

Reasoning burn is not monotonic in the rung (claude-sonnet-5 billed 0 tokens
at `xhigh` and 120 at `max`; gpt-5.6-sol billed 0 at every rung on this
prompt), so the rungs are recorded as accepted-or-not, not as a cost model.

### Declared output ceilings on the wire (round 8)

A row's `max_output_tokens` becomes the wire `max_tokens` for a
catalog-silent caller, so the ceilings taken from the gateway's metadata were
sent as an actual `max_tokens` rather than only read. `probe8-*`,
`reasoning_effort: low`, prompt "Reply with exactly: OK".

| model | `max_tokens` sent | result |
|---|---|---|
| `z-ai/glm-5.3` | 943718 | 200, `OK` |
| `moonshotai/kimi-k3` | 943718 | 200, `OK` |
| `x-ai/grok-4.6` | 450000 | 200, `OK` |
| `deepseek/deepseek-v4-pro` | 384000 | 200, `OK` |
| `openai/gpt-5.5` | 128000 | 200, `OK` |
| `google/gemini-3.8-flash` | 65536 | 200, `OK` |

No endpoint refused its own declared ceiling.

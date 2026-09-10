# deepseek/deepseek-v4.1-flash — OpenRouter live probe

Date: 2026-09-10. Same battery as the twelve rows in
`evidence/task-openrouter-support/`, against
`https://openrouter.ai/api/v1/chat/completions` with the account key from
`OPENROUTER_API_KEY`.

At probe time OpenRouter served exactly one v4.1 id — `deepseek-v4.1-flash`.
There is no `deepseek-v4.1` or `-pro` variant on the gateway.

## Gateway metadata (`GET /api/v1/models`)

| field | v4.1-flash | v4-flash (for comparison) |
|---|---|---|
| context | 1,048,576 | 1,048,576 |
| max completion tokens | 384,000 | 384,000 |
| input $/1M | **0.15** | 0.088606 |
| output $/1M | **0.60** | 0.177212 |
| input modalities | **text, image** | text |
| `parallel_tool_calls` in params | no | no |
| `seed` / `top_k` / `min_p` in params | yes | yes |

The window and the output ceiling are identical. What v4.1-flash adds is image
input; what it costs is 1.7x the input and 3.4x the output price. It is
therefore not a cheaper replacement for the v4-flash row, and both rows stay.

## Measured on the wire

| case | result | artifact |
|---|---|---|
| basic (`max_tokens: 64`) | 200, content `OK`, finish `stop`, 13 reasoning tokens | `probe-basic.json` |
| reasoning (`reasoning_effort: high`) | 200, answered `17 x 23 = 391`, `message.reasoning` string + `reasoning_details[reasoning.text]` | `probe-reasoning.json` |
| tool_choice required | 200, finish `tool_calls`, `get_weather({"city": "Seoul"})` — **on the second attempt**; the first was HTTP 429 "Provider returned error" | `probe-toolcall.json` |
| `max_tokens: 384000` (declared ceiling) | 200 | `probe-maxtokens-384000.json` |
| `reasoning_split: true` | 200 — the gateway drops the parameter it does not list, as with the other rows | `probe-reasoning-split.json` |
| streaming | `delta.reasoning` str x44 (+1 null) **and** `delta.reasoning_details` list x44, every detail `reasoning.text`; `[DONE]` reached, final chunk carried `usage` | `probe-stream.json` |

The 429 is a rate limit from the upstream provider, not a refusal: the same
request answered on the retry. It is recorded here so a later reader does not
mistake it for a capability finding.

## Effort ladder, rung by rung

`probe-effort-<rung>.json`, prompt "What is 17*23? Answer with the number.",
`max_tokens: 200`. Every rung answered 200.

| rung | reasoning tokens billed |
|---|---|
| none | **0** |
| minimal | 16 |
| low | 17 |
| medium | 17 |
| high | 18 |
| xhigh | 19 |
| max | 18 |

`none` is a real disable, not merely an accepted string — nothing was billed
for reasoning. So the row declares all seven rungs, unlike the five OpenRouter
ids whose endpoints refuse `none` with HTTP 400.

## What the row declares because of this

- `delta_details:reasoning` — both stream members arrive, same as the other
  twelve rows
- `split_reasoning_fields` + `drop_without_tool` — the reasoning item mirrors
  into `reasoning_details`, and replaying it on a tool-call turn is what keeps
  a chain intact
- the full seven-rung ladder
- `supports_seed = true`, `supports_parallel_tool_calls = false` — the
  gateway's own `supported_parameters` list, in both directions
- no modality override: the gateway accepts image here, so the
  `openai_chat_extended` base claim stands rather than being lowered

## Not measured

Image input was not exercised — no probe here sent an image. The row inherits
the base's image claim from the gateway's modality list, which is the same
standing as the other image-capable OpenRouter rows.

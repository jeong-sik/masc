# OpenRouter Live Probe — ten ids without a catalog row

Date: 2026-09-22. `probe.sh` in this directory ran every case against
`https://openrouter.ai/api/v1/chat/completions` with the account key in
`OPENROUTER_API_KEY`, in the shape of `evidence/task-openrouter-support`
(2026-09-10). The script checks the key's `limit_remaining` before each model
and stops below $0.50, because the same key serves a live runtime.

Spend: $0.083 for the whole run, read as the key's `limit_remaining` before
($2.0112) and after ($1.9285). `status.log` has every HTTP status in order.

## Cases per model

| file | request |
|---|---|
| `probe-<slug>-basic.json` | `max_tokens: 64`, "Reply with exactly: OK", `HTTP-Referer` + `X-Title` |
| `probe-<slug>-stream.sse` | `stream: true`, `reasoning_effort: high`, `max_tokens: 400`, "What is 17*23? Answer with the number." |
| `probe-<slug>-toolcall.json` | `tool_choice: "required"`, one `get_weather` tool, `max_tokens: 512` |
| `probe-<slug>-reasoning.json` | `reasoning_effort: high`, `max_tokens: 400`, "What is 17*23? Think it through, then give the number." |
| `probe-<slug>-reasoning-split.json` | the ladder prompt plus `reasoning_split: true` |
| `probe-<slug>-effort-<rung>.json` | one per rung `none … max`, `max_tokens: 200`, the ladder prompt |
| `probe-<slug>-ceiling.json` | `reasoning_effort: low`, `max_tokens` = the gateway's listed output ceiling |

## Results

| OpenRouter id | tool_choice required | `none` rung | other six rungs | ceiling as max_tokens | reasoning seen |
|---|---|---|---|---|---|
| `anthropic/claude-fable-5.1` | **400** "tool_choice: type \"tool\" and \"any\" are not supported for this model" | **400** mandatory | 200 | **402** credit (128000) | 10 tokens at `max` only |
| `anthropic/claude-haiku-4.5` | `get_weather` | 200, 0 tokens | 200 | 200 (64000) | 0 at `max_tokens` ≤ 400; 3628 at 4000 (see below) |
| `openai/gpt-6-astra` | `get_weather` | **400** mandatory | 200 | **402** credit (128000) | `reasoning.encrypted` + `reasoning.summary` |
| `openai/gpt-5.6-terra` | `get_weather` | 200, 0 tokens | 200 | 200 (128000) | 0 on every rung; 17 on the "think it through" prompt |
| `openai/gpt-5.6-luna` | `get_weather` | 200, 0 tokens | 200 | 200 (128000) | encrypted + summary; 13 at `xhigh`, 21 at `max` |
| `google/gemini-3.1-pro-preview` | `get_weather` | **400** mandatory | 200 | 200 (65536) | stream: details item only, no `delta.reasoning` text |
| `x-ai/grok-4.7` | `get_weather` | **400** mandatory | 200 | 200 (450000) | encrypted + summary, text in stream |
| `minimax/minimax-m3` | `get_weather` | 200 but **55 tokens** | 200 | 200 (512000) | `reasoning.text` |
| `qwen/qwen3.8-flash` | **400** "does not support being set to required or object in thinking mode" | 200, 0 tokens | 200 | 200 (131072) | `reasoning.text` |
| `z-ai/glm-5.3-flashx` | `get_weather` | **400** mandatory | 200 | 200 (131072) | `reasoning.text` |

"mandatory" is the gateway's text: "Reasoning is mandatory for this endpoint and
cannot be disabled".

Every model answered `basic` with `OK` / `stop`, answered `reasoning_split`
with content, and carried `usage` on the last stream chunk. No response used
`reasoning_content`; readable reasoning is `message.reasoning` with a mirrored
`reasoning_details[]`, as on 2026-09-10.

## Notes that shape the catalog rows

- **402 is the key's balance, not the endpoint's limit.** The gateway reserves
  `max_tokens × output price` against the remaining balance before it runs a
  request: "You requested up to 128000 tokens, but can only afford 42767". At
  $50/M that is a $6.40 reservation against $1.93. The fable and astra ceilings
  are therefore the gateway's listed values, not exercised ones. The same
  reservation applies to any request on this key that sends a large
  `max_tokens` to an expensive model.
- **haiku-4.5 needs room to reason.** At `max_tokens` 200 and 400 every rung
  billed 0 reasoning tokens. A second pair at `max_tokens: 4000`
  (`probe-claude-haiku45-reasoning-budget-{high,none}.json`, a prime-counting
  prompt) billed 3628 reasoning tokens at `high` and 0 at `none`.
- **minimax-m3 accepts `none` without disabling.** 55 reasoning tokens were
  billed on the `none` request, so the row does not list it.
- **qwen3.8-flash differs from qwen3.8-max on `none`.** Both refuse forced
  tool_choice in thinking mode; only flash takes `none` as a real disable.
- **fable-5.1 refused forced tool_choice with no reasoning field on the
  request.** Its thinking is always on, so a forced tool_choice fails whatever
  the caller asks for thinking.
- **glm-5.3-flashx** is refused by the Z.AI coding plan (code 1311) but served
  here.

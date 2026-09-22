# OpenRouter Live Probe — ten ids without a catalog row

Date: 2026-09-22. `probe.sh` in this directory ran every case against
`https://openrouter.ai/api/v1/chat/completions` with the account key in
`OPENROUTER_API_KEY`, in the shape of `evidence/task-openrouter-support`
(2026-09-10). The script checks the key's `limit_remaining` before each model
and stops below $0.50, because the same key serves a live runtime.

Spend: $0.083 for the whole run, read as the key's `limit_remaining` before
($2.0112) and after ($1.9285). The two haiku budget probes below ran while
probe.sh was running, so that figure includes them. The review follow-up's three
`*-toolcall-thinking.json` probes cost $0.0059 more (their `usage.cost`).

`status.txt` lists every committed response with its status, derived from the
files (probe.sh's own `status.log` is excluded by `*.log` in `.gitignore`).
`models-snapshot.json` is the gateway metadata the rows' window, ceiling, price
and parameter support were read from. Account identifiers the gateway echoed
in four error bodies are replaced with `<redacted-…>`.

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
| `minimax/minimax-m3` | `get_weather` | 200 but **55 tokens** | 200, but **content null** at high/xhigh/max | 200 (512000) | `reasoning.text` |
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
  billed 0 reasoning tokens. A second pair,
  `probe-claude-haiku45-reasoning-budget-{high,none}.json`, sent
  `reasoning_effort` `high` / `none`, `max_tokens: 4000` and "How many prime
  numbers are there between 1000 and 1100? Think it through, then give the
  count."; it billed 3628 reasoning tokens at `high` and 0 at `none`.
- **Forced tool_choice with thinking requested.** `probe-claude-{haiku45,sonnet5,opus5}-toolcall-thinking.json`
  sent `tool_choice: "required"` with `reasoning_effort: "high"` and
  `max_tokens: 4000`. All three called `get_weather` and billed 0 reasoning
  tokens: the gateway serves a forced call without thinking, so those rows keep
  the base tool_choice claims. fable-5.1 differs because its thinking cannot be
  turned off.
- **What "none billed 0" shows.** It is a real disable where other rungs billed
  reasoning on the same prompt: luna (13 at `xhigh`, 21 at `max`), qwen3.8-flash
  and haiku-4.5 at `max_tokens` 4000. terra billed 0 on every rung, so for
  terra it shows only that `none` is accepted.
- **minimax-m3 is not bound.** It accepts `none` without disabling (55
  reasoning tokens billed), and at `high`, `xhigh` and `max` the Novita upstream
  answered `finish_reason: stop` with `content: null` and the answer inside
  `reasoning`. The seed binds OpenRouter ids at `high`, so a keeper turn there
  would come back empty. The gateway lists `reasoning` but not
  `reasoning_effort` for this id, and its `top_provider.context_length` is
  524288 against a top-level 1048576. minimax-m3 stays reachable through the
  ollama_cloud binding.
- **qwen3.8-flash differs from qwen3.8-max on `none`.** Both refuse forced
  tool_choice in thinking mode; only flash takes `none` as a real disable.
- **fable-5.1 refused forced tool_choice with no reasoning field on the
  request.** Its thinking is always on, so a forced tool_choice fails whatever
  the caller asks for thinking.
- **glm-5.3-flashx** is refused by the Z.AI coding plan
  (`zai-coding-plan-glm53-flashx.json`, code 1311) but served here. The gateway
  lists `response_format` for it but not `structured_outputs`, so its row turns
  structured output off.

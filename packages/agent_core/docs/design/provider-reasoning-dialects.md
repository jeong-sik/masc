# Provider Reasoning Dialects

Date: 2026-06-29, surface facts checked 2026-09-18

## Purpose

agent_core owns provider and transport behavior. MASC and other agent runtimes should
consume typed agent_core facts instead of matching model names or provider-specific
strings when they decide how to display, replay, pause, or interrupt reasoning.

`Llm_provider.Reasoning_dialect` is the typed surface for those facts. It is
derived from the existing capability catalog and provider defaults, so it does
not introduce a second model registry. The capability model deliberately splits
thinking enable/depth control from historical-reasoning preserve/replay control:
current models such as Kimi K2.7-code can require reasoning replay while
accepting no request-time thinking parameter.

## Current Dialects

| Thinking control format | Preserve control format | Dialect meaning | Replay policy |
| --- | --- | --- | --- |
| `Thinking_object` | `No_preserve_thinking_control` | DeepSeek-style top-level `thinking` object, optional `reasoning_effort`, side-channel `reasoning_content` | Drop reasoning between plain user turns, preserve reasoning after assistant tool calls |
| `Thinking_object_adaptive` | `No_preserve_thinking_control` + `reasoning_output_format="split_reasoning_fields"` / `reasoning_replay="preserve_always"` when documented | MiniMax-style top-level `thinking` object with `type:"adaptive"` / `type:"disabled"` plus `reasoning_split=true` for side-channel output, no effort/depth field | Replay policy is explicit catalog data; MiniMax-M3 requires complete assistant replay |
| `Thinking_object_only` | `Thinking_object_keep_all` | Top-level `thinking` object without effort plus `thinking.keep="all"` when requested | Preserve historical `reasoning_content` when `preserve_thinking=true` |
| `Chat_template_kwargs` | `Chat_template_kwargs_preserve_thinking` | Self-hosted chat-template kwargs such as Qwen `enable_thinking` / `preserve_thinking` | Preserve historical reasoning only when requested |
| `No_thinking_control` | `Always_preserved_thinking` | Latest Kimi-style models whose thinking is provider-controlled and whose historical `reasoning_content` must remain in messages | Always replay historical reasoning; emit no thinking request field; omit fixed sampling knobs such as `temperature` / `top_p` |
| `Chat_template_token` | `No_preserve_thinking_control` | Template token injection such as Gemma `<\|think\|>` | No mandatory replay; parse visible thought channel from generated text |
| `Ollama_think` | `No_preserve_thinking_control` | Ollama native `/api/chat` top-level `think` bool/level, with thoughts in `message.thinking` | No mandatory replay; parse Ollama thinking side channel |
| `Reasoning_effort` | `No_preserve_thinking_control` | OpenAI-compatible `reasoning_effort` field | Set by the row, not by the dialect: OpenRouter and xAI both carry this field and both require the previous turn's reasoning back (see Surface facts) |
| `Anthropic_thinking` | built-in | Claude Messages API `thinking` blocks. Older/current manual-thinking models use `thinking: {type:"enabled", budget_tokens:N}`; adaptive models use `thinking: {type:"adaptive"}` plus optional `output_config.effort`. | Preserve thinking blocks in history; Claude filters relevant blocks |
| `Gemini_thinking_config` | built-in | Gemini native `generationConfig.thinkingConfig`. Gemini serves `thinkingLevel`; thought parts/signatures carry visible summaries/tool continuity. | Preserve tool-call-linked thought signatures |

## Surface facts

Checked 2026-09-18 against each vendor's current documentation. A cell reads
"not documented" when the vendor's pages do not answer it; none of them is
filled by analogy with another provider.

Two facts here do not fit the axes above, and both are load-bearing.

**Whether thinking can be turned off is a model fact, not a wire fact.** Grok
cannot be asked to stop at all, Kimi's k3 cannot and its k2.6 can, GLM could
until 5.3, and Qwen publishes a list of models that cannot. A row that inherits
a provider preset therefore inherits a claim nobody measured for it.

**A surface can accept the off value and keep thinking anyway.** MiniMax states
it for its M2.x models. The capability record has no way to say that: the row
reads as one that can be disabled, the request is admitted, and the model
reasons into a reply the caller believes is deterministic — the corruption
[Complete_common.Disable_not_encodable] exists to prevent, arriving through the
door that check leaves open.

| Surface | Wire | Thinking off | Effort ladder | Chain of thought | Replay |
| --- | --- | --- | --- | --- | --- |
| DeepSeek | OpenAI chat | `thinking.type`, on by default | enum `none`, `low`, `high`, `max` (default `high`); a value outside it is absorbed, not refused (`minimal`→`low`, `medium`/`xhigh`→`high`, `ultra`→`max`). The reference and the guide disagree on where the field sits | `reasoning_content`, same in stream deltas | required for every earlier turn **when the request carries `tools`**, ignored when it does not |
| xAI Grok | Responses (chat completions is legacy) | cannot be disabled | `low`, `medium`, `high`, `xhigh`; no `none`. An unsupported level is downgraded silently, not refused | encrypted, via `include: ["reasoning.encrypted_content"]`; chat completions returns none | required; omitting it is documented as the first cause of cache misses |
| Qwen (Model Studio) | OpenAI chat / DashScope native / Responses | `enable_thinking`, in `extra_body` on the compatible wire; a published list of models cannot be disabled | `reasoning_effort` documented for qwen3.8-omni-flash only: `none` … `max`, default `xhigh` | `reasoning_content` | not required by default; read only under `preserve_thinking=true`, and its absence is not an error |
| OpenRouter | OpenAI chat + Responses | `reasoning.enabled` / `reasoning.exclude` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; a level the model lacks is mapped to the nearest one, not refused | `reasoning_details` plus plain `reasoning`; deltas carry `reasoning_details` | required: "the entire sequence of consecutive reasoning blocks must match the outputs generated by the model during the original request" |
| vLLM | OpenAI chat + Responses | `chat_template_kwargs`, **key set by the model's template** (`enable_thinking` for Qwen3, `thinking` for Granite and DeepSeek-V3.1); a key the template does not declare is dropped without error | `reasoning_effort`: `none` disables, `low`/`medium`/`high` enable | `reasoning` — renamed from `reasoning_content`, and the old name now reads back empty | not documented |
| llama.cpp | OpenAI chat + Anthropic messages | `chat_template_kwargs`, `--reasoning on\|off\|auto`, `--reasoning-budget` | only `none` is interpreted; every other value is handed to the template | `reasoning_content`, moved by `--reasoning-format` (`none` leaves it inline in `content`) | server can keep it (`--reasoning-preserve`); whether the client must send it back is not documented |
| MiniMax platform | OpenAI chat | `thinking.type`, on by default — **and M2.x keeps thinking when told to stop** | not documented | `<think>` inline in `content`, or split into `reasoning_content` + `reasoning_details` under `reasoning_split` | the whole assistant message must stay in history |
| MiniMax Token Plan (was Coding Plan) | Anthropic messages, `api.minimax.io/anthropic` | `thinking.type`, **off by default** | not documented | Anthropic `thinking` blocks | thinking blocks must be passed back unchanged, named for tool-use conversations |
| GLM platform | OpenAI chat + Responses + Anthropic messages | `thinking.type`, on by default; GLM-5.3 and 5.3-Flash can only be enabled | the reference lists seven values, the model guide lists `low`, `high`, `max`; they disagree | `reasoning_content` | inverted default: `thinking.clear_thinking` is `true`, which strips earlier turns. Under `false` the blocks travel full, unmodified and in order |
| GLM coding plan | Anthropic messages + OpenAI chat under `/api/coding/paas/v4` | not documented | not documented | not documented | not documented |
| Kimi platform | OpenAI chat + Responses + Anthropic messages | k3 cannot be disabled; k2.6 takes `thinking.type` | `low`, `high`, `max` (default `max`); no `none` | `reasoning_content` on the OpenAI wire, `thinking` blocks with a `signature` on the Anthropic one | required on both wires, the Anthropic one unchanged and including the signature |
| Kimi coding models | the same endpoints; only the model id differs, so it is not a separate surface | cannot be disabled: `thinking.type` accepts `"enabled"` alone, and `thinking.keep` is fixed at `"all"` with any other value an error | not documented; these models carry the `thinking` object, and the effort ladder belongs to k3 | as the platform row | forced, and there is no field that turns it off |

Sources: <https://api-docs.deepseek.com/guides/thinking_mode>,
<https://docs.x.ai/developers/model-capabilities/text/reasoning>,
<https://www.alibabacloud.com/help/en/model-studio/deep-thinking>,
<https://openrouter.ai/docs/use-cases/reasoning-tokens>,
<https://docs.vllm.ai/en/latest/features/reasoning_outputs.html>,
<https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>,
<https://platform.minimax.io/docs/api-reference/text-chat-openai>,
<https://platform.minimax.io/docs/api-reference/text-anthropic-api>,
<https://docs.z.ai/api-reference/llm/chat-completion>,
<https://platform.kimi.ai/docs/api/chat>.

Where two of a vendor's own pages disagree (DeepSeek on the effort field's
position, GLM on the ladder), the disagreement is the finding. Neither page is
authority enough to declare a ladder from; that takes a probe.

## Evidence

- DeepSeek official docs: thinking defaults to enabled. The enum is `none`,
  `low`, `high`, `max`, and a value outside it is absorbed rather than refused
  — `minimal` maps to `low`, `medium` and `xhigh` map to `high`, `ultra` maps
  to `max`. `temperature`, `presence_penalty` and `frequency_penalty` have no
  effect in thinking mode and raise no error either; `top_p` does take effect
  but is floored at 0.95. `reasoning_content` must be replayed for every
  earlier turn when the request carries `tools`, and is ignored when it does
  not. Source: <https://api-docs.deepseek.com/guides/thinking_mode>,
  <https://api-docs.deepseek.com/api/create-chat-completion>, corrected
  2026-09-18 (the mapping recorded here on 2026-06-14 had `low` going to
  `high` and `xhigh` going to `max`; neither is what the table says).
- Gemma official docs: Gemma 4 thinking is enabled through chat-template
  control (`enable_thinking=True` in the processor), generated output contains
  a thought channel plus answer content, and parsing requires keeping special
  tokens. Source: <https://ai.google.dev/gemma/docs/capabilities/thinking?hl=ko>,
  checked 2026-06-14.
- Claude official docs: extended thinking uses `thinking` blocks, during tool
  use those blocks must be passed back unchanged, Opus 4.7/4.8 reject manual
  `budget_tokens` and require adaptive thinking, and effort is carried through
  `output_config.effort`. Source:
  <https://platform.claude.com/docs/en/build-with-claude/extended-thinking>,
  <https://platform.claude.com/docs/en/build-with-claude/effort>, checked
  2026-06-14.
- OpenAI official docs: reasoning models expose `reasoning.effort`; currently
  documented values include `none`, `minimal`, `low`, `medium`, `high`, and
  `xhigh`, with support/defaults varying by model. Prior reasoning state can
  be preserved with `previous_response_id` or by manually passing reasoning
  items forward. Source:
  <https://platform.openai.com/docs/guides/reasoning>, checked 2026-06-14.
- Gemini official docs: Gemini exposes `thinkingConfig`; Gemini 3+ should use
  `thinkingLevel`; optional thought
  summaries are marked on response parts. Source:
  <https://ai.google.dev/gemini-api/docs/thinking>, checked 2026-06-14.
- Qwen official docs: OpenAI-compatible Qwen thinking uses
  `enable_thinking`, optional `thinking_budget`, side-channel
  `reasoning_content`, and `preserve_thinking` for carrying historical
  assistant reasoning forward. Source:
  <https://www.alibabacloud.com/help/en/model-studio/deep-thinking>, checked
  2026-06-14.
- Kimi official docs: Kimi K2.7-code preserves thinking by default, does not
  support non-thinking mode, accepts no useful request-time `thinking.disabled`
  strategy, and requires historical assistant `reasoning_content` to remain in
  `messages`. Kimi's thinking-model guide also says not to pass `temperature`
  for K2.7-code / K2.6; the API reference documents K2.7-code fixed
  `temperature=1.0` and fixed `top_p=0.95`. Older Kimi variants can be
  described through the separate preserve capability axis if an operator needs
  them. Sources:
  <https://platform.kimi.ai/docs/guide/use-kimi-k2-thinking-model>,
  <https://platform.kimi.ai/docs/api/chat>, checked 2026-07-04.

## Boundary

This module does not schedule tool calls, pause keepers, or decide whether a
user interruption should preempt a running turn. It only exposes provider
semantics. Agent runtimes should use these facts to build their own control
loops without copying provider-specific rules into MASC.

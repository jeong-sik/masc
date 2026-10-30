# Ollama Cloud capability probe — 2026-08-29

## Evidence

- Endpoint: `https://ollama.com/v1/chat/completions` and `https://ollama.com/api/chat`
- Model list: `GET https://ollama.com/api/tags` — 19 models served
- Docs: <https://docs.ollama.com/api/openai-compatibility>, <https://docs.ollama.com/capabilities/structured-outputs>
- Upstream issues read: ollama/ollama#17987 (OPEN), #16389 (OPEN), #16632 (CLOSED)

## Timestamp

2026-08-29T12:5x KST, single session, live account key.

## Confidence

High for the per-model results below (each mismatch re-run twice, same output).
Medium for absence claims — a single session cannot rule out intermittent behaviour,
and #17987 describes the split as intermittent.

## Method

Three requests per model:

1. `response_format: {"type":"json_object"}`, `temperature: 0`, prompt `Return JSON: {"test":1}`
2. `reasoning_effort` of `none` then `low`, prompt `What is 17*23? Number only.`
3. one `tools` definition, prompt asking for the call

## Results — 19 served models

| model | json_object | effort=none reasoning | effort=low | tools |
|---|---|---|---|---|
| deepseek-v4-flash:0731 | ok | 0 | 37 | ok |
| deepseek-v4-pro:0813 | ok | 0 | 60 | ok |
| gemma4:31b | **fenced** | 0 | 148 | ok |
| glm-5.1 | ok | 0 | 376 | ok |
| glm-5.2 | ok | 0 | 342 | ok |
| glm-5.3 | **fenced** | 0 | 9 | ok |
| glm-5.3-flash | ok | 0 | 3 | ok |
| gpt-oss:120b | ok | 121 | 24 | ok |
| gpt-oss:20b | ok | 203 | 20 | ok |
| kimi-k2.6 | ok | 0 | 247 | ok |
| kimi-k2.7-code | ok | 0 | 54 | ok |
| kimi-k3 | **fenced** | 0 | 3 | ok |
| minimax-m2.7 | ok | 255 | 217 | ok |
| minimax-m3 | ok | 146 | 130 | ok |
| mistral-large-3:675b | **prose + fence** | 0 | 0 | ok |
| nemotron-3-nano:30b | ok | 0 | 916 | ok |
| nemotron-3-super | ok | 0 | 72 | ok |
| nemotron-3-ultra | ok | 0 | 61 | ok |
| qwen3.5:397b | **empty content** | 0 | 869 | ok |

### json_schema is ignored everywhere it was tried

`response_format: {"type":"json_schema", ...}` with a two-key strict schema returned
plain prose from `deepseek-v4-flash:0731`, `minimax-m3`, `gpt-oss:120b`, and
`qwen3.5:397b`. No error, no schema keys.

Native `/api/chat` with `format: <schema>` behaved the same on
`deepseek-v4-flash:0731` and `minimax-m3` (3 runs each on minimax). The prompt had
to ask for JSON before any JSON appeared, and the keys were the model's own
(`{"apples": 391}`) rather than the requested `answer`/`unit`.

This contradicts the `config/runtime.toml` note on
`[models.minimax-m3-native-structured]` claiming native `format` enforces where
`/v1` does not. Neither enforces on these cloud tags.

### reasoning_effort is per-model, not per-provider

Fifteen of nineteen return zero reasoning characters at `effort=none`. The four
that ignore it are both minimax tags and both gpt-oss tags. GPT-OSS is expected:
<https://docs.ollama.com/capabilities/thinking> states it takes `low|medium|high`
only. minimax matches ollama/ollama#17987, where a maintainer picked the issue up
on 2026-08-27 and Discord guidance quoted in the thread says minimax thinking
cannot be turned off.

### Omitting reasoning_effort is itself a failure mode

`qwen3.5:397b` with no effort field returned empty content and 2,082–2,184
characters of reasoning, twice. With `effort=none` it answered. The official
compatibility page states Ollama auto-enables thinking for capable models when no
`reasoning_effort` is provided.

## Delta

Two catalog rows advertised `supports_response_format_json = true` while fencing
their output. `structured_output_support` projects that flag to `Json_object_only`,
whose consumer parses the content, so a fenced block fails there. Both are now
declared false.

The `mistral-large-3:675b` row already carried a 2026-06-29 note recording the
fencing; it lowered only the schema flag. Two months later the behaviour is
unchanged.

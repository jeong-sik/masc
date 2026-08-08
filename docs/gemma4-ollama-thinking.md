# Gemma 4 QAT on Ollama

This note covers Gemma 4 QAT GGUF models served by local Ollama and consumed
through OAS.

## Summary

Gemma 4 thinking is chat-template controlled. Do not treat it as the generic
Ollama `/api/chat` `think` boolean path.

For the Unsloth Gemma 4 QAT GGUF models, current Ollama advertises completion,
tools, and vision capability, but rejects a top-level `think: true` request.
The working path is:

1. Register the model with `thinking_control_format = "chat_template_token"`.
2. Register the exact token with `thinking_control_token = "<|think|>"`.
3. Omit the top-level `think` field when thinking is enabled.
4. Prefix the system turn with the catalog-declared token.
5. Parse `message.thinking` from the Ollama response.

OAS now handles that path for model IDs matching:

```toml
id_prefix = "hf.co/unsloth/gemma-4"
```

## Model Catalog Entry

The built-in `models.toml` entry is:

```toml
[[models]]
id_prefix = "hf.co/unsloth/gemma-4"
base = "ollama"
max_context_tokens = 262144
supports_tools = true
supports_tool_choice = false
supports_reasoning = true
supports_extended_thinking = true
supports_reasoning_budget = false
thinking_control_format = "chat_template_token"
thinking_control_token = "<|think|>"
supports_multimodal_inputs = true
supports_image_input = true
supports_native_streaming = true
supports_seed = true
input_per_million = 0.0
output_per_million = 0.0
```

`supports_reasoning_budget = false` is intentional. Gemma 4 thinking is an
on/off chat-template mode here, not a budgeted `reasoning_effort` or
`thinking_budget` transport.

## Local Ollama Probe

Pull or run the model with Ollama:

```sh
ollama run hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL
```

Inspect the server-side model metadata:

```sh
curl -sS http://127.0.0.1:11434/api/show \
  -H 'Content-Type: application/json' \
  -d '{"model":"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"}' \
  | jq '{capabilities:.capabilities, template:.template, parameters:.parameters}'
```

The failure mode that this OAS patch avoids:

```sh
curl -sS -i http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL",
    "messages":[{"role":"user","content":"Say OK only."}],
    "stream":false,
    "think":true,
    "options":{"num_predict":8}
  }'
```

Expected failure:

```json
{"error":"\"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL\" does not support thinking"}
```

The working request shape omits `think` and uses the template token:

```sh
curl -sS http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL",
    "messages":[
      {"role":"system","content":"<|think|>\nYou are a helpful assistant."},
      {"role":"user","content":"Solve 19*21. Give final answer briefly."}
    ],
    "stream":false,
    "options":{"num_predict":256,"temperature":1.0,"top_p":0.95,"top_k":64}
  }' | jq '{content:.message.content, thinking:.message.thinking}'
```

Expected shape:

```json
{
  "content": "399",
  "thinking": "..."
}
```

## OAS Usage

Use the normal Ollama provider config. Set `enable_thinking=true` when the turn
should expose Gemma 4 thinking:

```ocaml
let config =
  Llm_provider.Provider_config.make
    ~kind:Ollama
    ~model_id:"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
    ~base_url:"http://127.0.0.1:11434"
    ~system_prompt:"You are a helpful assistant."
    ~enable_thinking:true
    ~temperature:1.0
    ~top_p:0.95
    ~top_k:64
    ()
;;
```

When `enable_thinking=true`, OAS sends a system message that starts with
`<|think|>` and intentionally omits `think`. When thinking is disabled, OAS
keeps the existing generic Ollama behavior and sends `think:false`.

The Ollama response parser already maps `message.thinking` to an OAS
`Thinking` content block.

## Runtime Wiring

Host applications should reference the same local Ollama model through their
own provider/model configuration. If the local Ollama provider is not already
present, define it first:

```toml
[providers.ollama]
display-name = "Local Ollama"
protocol = "ollama-http"
endpoint = "http://localhost:11434"
```

Then add the model and provider-model binding:

```toml
[models.gemma4-26b-a4b-qat]
api-name = "hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
max-context = 262144
tools-support = true
thinking-support = true
streaming = true

[ollama.gemma4-26b-a4b-qat]
max-concurrent = 1
```

Then bind the model to the host runtime using that runtime's own assignment
mechanism:

```toml
[runtime.assignments]
"agent-name" = "ollama.gemma4-26b-a4b-qat"
```

Keep concurrency low at first. The 26B-A4B QAT model is large enough that
parallel agent turns can compete for local GPU/VRAM even when single-turn
latency is acceptable.

## Operational Notes

- Do not set `OAS_OLLAMA_THINK_DEFAULT=true` globally unless every Ollama model
  in that process can tolerate the selected thinking wire format.
- For Gemma 4 QAT, prefer explicit per-turn `enable_thinking=true` over global
  defaults.
- Do not add previous turn thoughts back into multi-turn history. Keep only the
  final assistant response in history unless a consumer intentionally persists
  thinking blocks for observability.
- Use the documented sampling defaults for Gemma 4 unless a workload has a
  measured reason to change them: `temperature=1.0`, `top_p=0.95`, `top_k=64`.

## Evidence

- Source: Unsloth Gemma 4 QAT documentation provided by the operator in the
  implementation request. Checked: 2026-06-12 Asia/Seoul. Confidence: High for
  the chat-template contract.
- Source: local Ollama probes against
  `hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL`. Checked:
  2026-06-12 Asia/Seoul. Confidence: High for the local `think:true` failure
  and `message.thinking` success path.

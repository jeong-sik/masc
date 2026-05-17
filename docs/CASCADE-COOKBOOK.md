# Cascade Cookbook

Copy-paste examples for declarative `config/cascade.toml`.

The old flat profile cookbook is retired. Do not write top-level profile tables
with inline model lists; declare providers, models, bindings, tiers,
tier-groups, and routes explicitly.

## GLM Coding Plan + Kimi CLI

```toml
[providers.glm-coding]
display-name = "Zhipu GLM Coding"
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[providers.kimi_cli]
display-name = "Moonshot Kimi CLI"
protocol = "kimi-cli"
command = "kimi"
is-non-interactive = true

[providers.kimi_cli.credentials]
type = "env"
key = "MOONSHOT_API_KEY"

[models.glm-5-turbo]
api-name = "glm-5-turbo"
max-context = 128000
tools-support = true
streaming = true

[models.kimi-coding]
api-name = "kimi-for-coding"
max-context = 128000
tools-support = true
streaming = true

[glm-coding.glm-5-turbo]
is-default = true
max-concurrent = 2

[kimi_cli.kimi-coding]
is-default = true
max-concurrent = 1

[tier.glm-coding-with-spark]
members = ["glm-coding.glm-5-turbo", "kimi_cli.kimi-coding"]
strategy = "failover"

[tier-group.glm-coding-with-spark]
tiers = ["glm-coding-with-spark"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "tier-group.glm-coding-with-spark"
```

## Ollama Fallback

Use the same shape for local Ollama or a compatible remote Ollama endpoint.
Only the provider `endpoint` changes.

```toml
[providers.ollama]
display-name = "Ollama HTTP"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
api-name = "qwen3"
max-context = 262144
tools-support = true
streaming = true

[ollama.qwen3]
is-default = true
max-concurrent = 1

[tier.local_recovery]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.local_recovery]
tiers = ["local_recovery", "glm-coding-with-spark"]
strategy = "priority_tier"
fallback = true

[routes.phase_recovery]
target = "tier-group.local_recovery"
```

## Qwen3.6 35B-A3B MTP GGUF

Use the repo path, not only the GGUF basename, to identify this model. The
MTP artifact is:

```text
unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
unsloth/Qwen3.6-35B-A3B-MTP-GGUF/mmproj-F16.gguf
```

Do not confuse it with the non-MTP repo:

```text
unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
```

The basename is intentionally similar, but the artifacts are not identical.
On 2026-05-17, Hugging Face HEAD metadata differed:

| Repo | Size | Linked etag prefix |
| --- | ---: | --- |
| `Qwen3.6-35B-A3B-GGUF` | `22,360,456,160` | `707a55...` |
| `Qwen3.6-35B-A3B-MTP-GGUF` | `22,853,663,008` | `55983c...` |

The llama.cpp MTP shape is main GGUF plus projector plus speculative decoding:

```bash
export QWEN36_MTP_DIR="/path/to/unsloth/Qwen3.6-35B-A3B-MTP-GGUF"

./build/bin/llama-server \
  --model "$QWEN36_MTP_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
  --mmproj "$QWEN36_MTP_DIR/mmproj-F16.gguf" \
  --alias qwen-local-35b-a3b \
  -ngl 99 \
  -c 65536 \
  -fa on \
  -np 1 \
  --temp 0.7 \
  --top-p 0.8 \
  --top-k 20 \
  --presence-penalty 1.5 \
  --min-p 0.00 \
  --spec-type draft-mtp \
  --spec-draft-n-max 6 \
  --reasoning off \
  --host 127.0.0.1 \
  --port 8080
```

Cascade entries should keep the context and output caps at the model level.
Do not set a per-keeper `max-output` override unless the keeper truly needs a
different cap.

```toml
[providers.local_mtp]
display-name = "Local Qwen3.6 35B-A3B MTP"
protocol = "openai-http"
endpoint = "http://127.0.0.1:8080"

[models.qwen36-35b-a3b-mtp-local]
api-name = "qwen-local-35b-a3b"
max-context = 65536
tools-support = true
thinking-support = true
streaming = true

[models.qwen36-35b-a3b-mtp-local.capabilities]
max-output-tokens = 8192
supports-tool-choice = true
supports-native-streaming = true
supports-response-format-json = true

[local_mtp.qwen36-35b-a3b-mtp-local]
is-default = true
max-concurrent = 1

[local_mtp.qwen36-35b-a3b-mtp-local.keeper]
temperature = 0.3
```

Runtime proof points:

- Process args include `--mmproj .../mmproj-F16.gguf`,
  `--spec-type draft-mtp`, and `--spec-draft-n-max 6`.
- `server.log` should include `creating MTP draft context`,
  `loaded multimodal model`, and `adding speculative implementation
  'draft-mtp'`.
- A smoke completion should include non-zero `timings.draft_n` and
  `timings.draft_n_accepted`.

Observed smoke on 2026-05-17 KST:

| Endpoint | Predicted tok/s | Draft generated | Draft accepted | Notes |
| --- | ---: | ---: | ---: | --- |
| local `127.0.0.1:8080` | `80-81` | `162` | `144` | 160-word repeat prompt, `reasoning off` |
| RunPod proxy | `212-215` | `197` | `156` | Same prompt; remote launch flags not locally visible |

Official source: <https://unsloth.ai/docs/models/qwen3.6#mtp-qwen3.6-35b-a3b>

## Notes

- Routes should target `tier-group.<name>` unless a caller intentionally needs a
  single tier or binding.
- Keep provider credentials in provider sub-tables; do not recreate per-profile
  `api_key_env` blocks.
- The checked-in seed is `config/cascade.toml`.

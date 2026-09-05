---
title: Local AI models
description: Uncomment the self-hosted provider the seed already ships, and run Keepers, the verifier and the librarian without a cloud key.
---

A local model server runs Keepers, the verifier and the librarian with no cloud
token at all.

**This is uncommenting, not authoring.** The `runtime.toml` that `masc init`
seeds already carries three self-hosted servers, commented out.

| Server | Provider id | In the seed |
| --- | --- | --- |
| llama.cpp `llama-server` | `llama_server` | commented, with a measured capability table |
| vLLM | `vllm` | commented, from the official docs |
| MLX | `mlx_server` | commented |
| Ollama (local) | `ollama` | **already live** at `http://localhost:11434` |

If local Ollama is all you want, there is nothing to do: it is the one provider
of the seeded five that needs no key.

The other three are commented for a reason the seed states itself — none of
those servers exists on a fresh machine, and `enabled = false` is not an option
here, because the setup wizard walks every declared provider and refuses one
whose bindings are all disabled ("has no concrete runtime binding").

## Run llama-server

```bash
llama-server \
  -m models/qwen-2.5-coder-32b-instruct-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 16384 \
  --n-gpu-layers 99
```

## Uncomment the block

Find this in `<base-path>/.masc/config/runtime.toml`, drop the `#`, and point
`endpoint` at the real address. A local server has no API key, so there is no
`credentials` block.

```toml
[providers.llama_server]
display-name = "llama.cpp llama-server"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:8080/v1"

[providers.llama_server.healthcheck]
path = "/models"
```

Set `api-name` to whatever that server reports at `/v1/models`.

## Declare the model, then bind it

Two places. `[models.*]` says what the model is; `[<provider>.<model>]` attaches
it to this server.

```toml
[models.qwen-2-5-coder-32b]
api-name = "qwen-2.5-coder-32b-instruct"
max-context = 16384
tools-support = true

[llama_server.qwen-2-5-coder-32b]
max-request-body-bytes = 1048576
```

Leave `max-request-body-bytes` out and **no Keeper turn reaches that runtime.**
Startup names it in a warning, but it is a common place to look like nothing is
running for no visible reason: of the 31 bindings the seed ships, only the 13
that declare this key can take a turn.

## Point a role at it

```toml
# as the workspace default
[runtime]
default = "llama_server.qwen-2-5-coder-32b"

# or on the verifier lane alone
[runtime.exact_output_lanes.verifier_exact]
slots = ["llama_server.qwen-2-5-coder-32b"]
```

The installer probes `healthcheck.path` while configuring, so a server that is
not up shows as `not running` in the wizard rather than failing quietly later.
The full schema is in [Configuration](/reference/config/).

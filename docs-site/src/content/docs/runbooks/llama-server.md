---
title: Local Models
description: Use a local llama.cpp / Ollama server as a no-key model source for Keepers, verifiers, and librarians.
---

A local model server lets Keepers, verifiers, and librarians run without spending
external cloud API tokens. Any OpenAI-compatible HTTP server works — `llama-server`
(llama.cpp), Ollama, LM Studio, or MLX.

## Running llama-server

```bash
llama-server \
  -m models/qwen-2.5-coder-32b-instruct-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 16384 \
  --n-gpu-layers 99
```

## Wiring it into MASC

Add the server as a provider in `<base-path>/.masc/config/runtime.toml`. A local
server needs no API key, so it has no `[providers.*.credentials]` block:

```toml
[providers.local_llama]
display-name = "Local llama.cpp"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:8080/v1"

[providers.local_llama.healthcheck]
path = "/models"
```

Declare the model and bind it to the provider:

```toml
[models.qwen-2.5-coder-32b]
api-name = "qwen-2.5-coder-32b-instruct"

[local_llama.qwen-2.5-coder-32b]
max-request-body-bytes = 1048576
```

Then point a role at the `<provider>.<model>` pair. Make it the default for every
turn, or assign it to a single lane such as the verifier:

```toml
# either the workspace default
[runtime]
default = "local_llama.qwen-2.5-coder-32b"

# or just the verifier lane
[runtime.exact_output_lanes.verifier_exact]
slots = ["local_llama.qwen-2.5-coder-32b"]
```

The installer probes the `healthcheck.path` at setup, so a server that is not
running shows as `not running` in the wizard rather than failing silently later.
See the [Configuration Reference](/reference/config/) for the full schema.

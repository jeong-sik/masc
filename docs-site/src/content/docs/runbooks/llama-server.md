---
title: Llama Server Runbook
description: Using local llama.cpp / Qwen as an offline judge and verifier in MASC.
---

MASC allows local LLMs to act as verifiers, judges, and librarians without consuming external cloud API tokens.

## Running llama-server

```bash
llama-server \
  -m models/qwen-2.5-coder-32b-instruct-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 16384 \
  --n-gpu-layers 99
```

## Configuring in MASC

In `.masc/config/runtime.toml`:

```toml
[providers.local_llama]
kind = "openai-compatible"
base_url = "http://127.0.0.1:8080/v1"
model = "qwen-2.5-coder-32b-instruct"

[roles]
verifier = "local_llama"
```

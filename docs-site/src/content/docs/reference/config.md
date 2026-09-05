---
title: Configuration Reference
description: Schema and examples for .masc/config/*.toml files.
---

All persistent runtime settings live in `<base-path>/.masc/config/`.

## Directory Structure

```text
.masc/config/
├── runtime.toml               # Provider catalog, [runtime].default, Keeper assignments
├── connectors.toml            # Slack, Discord, and external channel bindings
├── repositories.toml          # Registered repositories and checkout metadata
├── keeper_repo_mappings.toml  # Keeper-to-repository preferences
├── .env.local                 # Provider environment variables written by installer
└── keepers/                   # Per-Keeper profiles
    └── reviewer.toml
```

---

## 1. runtime.toml Example

```toml
[runtime]
default = "anthropic.claude-3-7-sonnet"

[runtime.assignments]
lead = "anthropic.claude-3-7-sonnet"
reviewer = "openai.gpt-4o"

[providers.anthropic]
kind = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"

[providers.local_llama]
kind = "openai-compatible"
base_url = "http://127.0.0.1:8080/v1"
model = "qwen-2.5-coder-32b-instruct"
api_key = "not-needed"
```

---

## 2. keepers/*.toml Example

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "docker" # "docker" | "microvm" | "remote_ssh" (host profile is refused)
mention_targets = ["operator"]

[keeper.tools]
native = "read" # "none" | "read" | "full"

instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""
```

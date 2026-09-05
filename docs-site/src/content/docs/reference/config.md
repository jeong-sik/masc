---
title: Configuration Reference
description: Schema and examples for .masc/config/*.toml files.
---

Persistent runtime settings live in `<base-path>/.masc/config/`. The installer
seeds a complete, working `runtime.toml`, so in practice you **edit the seeded
file** rather than write one from scratch.

## Directory Structure

```text
.masc/config/
├── runtime.toml    # provider catalog, model bindings, [runtime].default, lanes
├── .env.local      # provider API keys, written by the installer (chmod 600)
└── keepers/        # per-Keeper profiles, one <name>.toml each
    └── reviewer.toml
```

Connector settings (Discord, Slack) are not a separate file: they are tables
inside `runtime.toml` (e.g. `[discord]`). `repositories.toml` and
`keeper_repo_mappings.toml` appear once you use those features.

---

## runtime.toml

`[runtime].default` names the model a turn uses when nothing more specific
applies. It is a `<provider>.<model>` pair — both halves must be defined below.

```toml
[runtime]
default = "deepseek.deepseek-v4-flash"
```

A **provider** describes how to reach a backend:

```toml
[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers.deepseek.healthcheck]
path = "/models"

[providers.deepseek.credentials]
type = "env"
key = "DEEPSEEK_API_KEY"
```

A **model** is declared once, then **bound** to a provider. The binding table is
what makes the pair dispatchable, and it carries per-binding limits:

```toml
[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"

[deepseek.deepseek-v4-flash]
wizard-default = true
max-request-body-bytes = 1048576
```

Roles such as the verifier are assigned by listing `<provider>.<model>` slots in
a lane, not with a `[roles]` table:

```toml
[runtime.exact_output_lanes.verifier_exact]
slots = ["deepseek.deepseek-v4-flash"]
```

---

## keepers/<name>.toml

A Keeper's profile. The installer does not write these; create them with
`masc keeper-create` (or the TUI's Keepers surface), which fills in the required
`sandbox_profile` and `network_mode`. A profile looks like:

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = false
sandbox_profile = "docker"   # "docker" | "microvm" | "remote_ssh"; host is refused
network_mode = "none"        # "none" | "inherit" | "policy"; "none" blocks all guest network
instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""

[keeper.tools]
native = "read"              # "none" | "read" | "full" — host tools the Keeper may call
```

See [Keeper Sandbox](/runbooks/sandbox/) for what each `sandbox_profile` means.

---
title: Configuration Reference
description: Schema and examples for .masc/config/*.toml files.
---

Persistent runtime settings live in `<base-path>/.masc/config/`. The installer
seeds a complete, working `runtime.toml`, so in practice you **edit the seeded
file** rather than write one from scratch.

## Directory Structure

```text
.masc/config/                     # seeded by `masc init` / `masc setup`
├── runtime.toml                  # provider catalog, model bindings, [runtime].default, lanes, maintenance, wiki_contents, sandbox, tui
├── candle.toml                   # optional Candle half-life, [payout], and [shop.pricing] policy
├── sandbox-image-builds.toml     # promoted sandbox image tags per runtime store
├── prompts/                      # role prompt templates (keeper.md, librarian, verifier, ...)
├── tools/                        # tool declarations
├── identity/                     # keeper identity & portrait assets
├── themes/                       # TUI colour schemes
├── mcp/                          # MCP client templates
└── keepers/                      # per-Keeper profiles (<name>.toml)
```

Connector settings (Discord, Slack) are tables inside `runtime.toml` (e.g. `[discord]`). `repositories.toml` appears once you register a repository.

There is no `.env.local` in a binary install. Settings live in TOML and credentials live in the
environment the server is started in — see [Environment variables](/reference/env-contract/).

## What the catalog ships

`config/runtime.toml` seeds **nine active providers**: five HTTP API providers (requiring a credential variable), one local HTTP provider (`ollama`), and three CLI subscription providers:

| Provider | Protocol / Endpoint or Command | Credential |
| --- | --- | --- |
| `ollama_cloud` | `https://ollama.com/v1` (`openai-compatible-http`) | `env`: `OLLAMA_CLOUD_API_KEY` |
| `deepseek` | `https://api.deepseek.com` (`openai-compatible-http`) | `env`: `DEEPSEEK_API_KEY` |
| `glm-coding` | `https://api.z.ai/api/coding/paas/v4` (`openai-compatible-http`) | `env`: `ZAI_API_KEY` |
| `kimi_coding` | `https://api.kimi.com/coding/v1` (`openai-compatible-http`) | `env`: `KIMI_API_KEY` |
| `openrouter` | `https://openrouter.ai/api/v1` (`openai-compatible-http`) | `env`: `OPENROUTER_API_KEY` |
| `ollama` | `http://localhost:11434` (`ollama-http`) | none (local) |
| `claude_code` | `claude` (`claude-code` CLI) | CLI login |
| `codex_subscription` | `codex` (`codex-app-server` CLI) | CLI login |
| `antigravity_subscription` | `agy` (`antigravity-cli`) | `file`: `~/.gemini/antigravity-cli/antigravity-oauth-token` |

`llama_server`, `vllm`, and `mlx_server` ship commented out — see
[Local AI models](/runbooks/llama-server/).

**Every seeded binding can take a Keeper turn.** Whether a request is too large is the provider's verdict: MASC sends
the composed request and, on a refusal, evicts the oldest carried history and
asks again.

## runtime.toml

`[runtime].default` names the model a turn uses when nothing more specific
applies. It is a `<provider>.<model>` pair — both halves must be defined below.

```toml
[runtime]
default = "ollama_cloud.ollama-cloud-glm-5-3-flash"
```

A **provider** describes how to reach a backend. Any keyed HTTP provider must declare `[providers.<id>.credentials]` (`type = "env"` and `key = "<ENV_VAR>"`, or `type = "file"` and `path = "..."`); omitting `[providers.<id>.credentials]` on a keyed provider causes startup/validation to reject the provider with `credential_undeclared`:

```toml
[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"
# An exact-output lane slot on this provider needs a whole-request deadline.
# connect-timeout-s stops at the response headers, so it does not count.
exact-body-timeout-s = 1200.0

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
```

Roles such as the verifier are assigned by listing `<provider>.<model>` slots in
a lane, not with a `[roles]` table:

```toml
[runtime.exact_output_lanes.verifier_exact]
slots = ["glm-coding.glm-5-3", "ollama_cloud.ollama-cloud-deepseek-v4-1-flash"]
max_output_tokens = 8192
```

A slot's HTTP provider must declare `exact-body-timeout-s`. A save that adds a slot
without it is refused; at boot such a slot is left out of its lane and the
runtime startup report names the lane, the slot and the provider.

### Additional `runtime.toml` tables

```toml
[wiki_contents]
# Injects the <base-path>/.masc/wiki table of contents at the start of each Keeper turn.
enabled = true

[maintenance]
# Day-file retention for dated JSONL stores under .masc/ (overridden by MASC_JSONL_RETENTION_DAYS).
jsonl_retention_days = 30

[sandbox]
# Optional nameserver for microVM Keeper guests (one IPv4 or IPv6 address).
microvm_dns = "1.1.1.1"

[tui]
# Optional SoundFont (.sf2 / .sf3) path for Board MIDI attachment playback via fluidsynth.
midi_soundfont = "/absolute/path/to/soundfont.sf2"
```

---

## keepers/<name>.toml

A Keeper's profile. Create profiles with `masc keeper-create` (or the TUI's Keepers surface), which fills in the required
`sandbox_profile`, `sandbox_image`, and `network_mode`. A profile looks like:

```toml
[keeper]
activation_mode = "autonomous"  # "manual" | "reactive" | "scheduled" | "autonomous"
sandbox_profile = "docker"      # "docker" | "microvm" | "remote_ssh" (no "local" or host profile)
sandbox_image = "base"          # "base" | "ocaml"
network_mode = "none"           # "none" | "inherit" | "policy"; "none" blocks all guest network
instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""

[keeper.tools]
native = "read"              # "none" | "read" | "full" — host tools the Keeper may call
```

See [Keeper Sandbox](/runbooks/sandbox/) for what each `sandbox_profile` and `sandbox_image` means.

---

## candle.toml (`[shop.pricing]`)

`<base-path>/.masc/config/candle.toml` configures the Candle reward currency (`half_life` and `[payout]`) and portrait accessory shop pricing. Under `[shop.pricing]`, `mode = "fixed"` charges the base prices from `[shop.prices_milli]`, while `mode = "supply_scaled"` scales accessory prices by circulating Candle supply relative to `target_per_keeper_milli` (clamped between `min_permille` and `max_permille` with the configured `rounding`).

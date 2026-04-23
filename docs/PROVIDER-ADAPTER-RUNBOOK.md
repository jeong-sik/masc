---
status: runbook
last_verified: 2026-04-23
code_refs:
  - lib/provider_adapter.ml
  - lib/provider_adapter.mli
---

# Provider Adapter Runbook

이 문서는 `MASC`에서 provider/runtime/auth를 어떻게 나누는지에 대한 SSOT다.

핵심 원칙:

- `runtime_kind`는 세 가지다:
  - `local`
  - `direct_api`
  - `cli_agent`
- auth는 공통화하지 않고 provider-native로 둔다.
- swarm의 기본 substrate는 여전히 local-first다.

## Canonical Matrix

| Canonical name | Runtime | Auth | Notes |
|---|---|---|---|
| `llama` | `local` | `none` | `LLAMA_SERVER_URL` OpenAI-compatible local runtime |
| `glm` | `direct_api` | `api_key` (`ZAI_API_KEY`) | current Z.ai direct path |
| `claude-api` | `direct_api` | `api_key` (`ANTHROPIC_API_KEY`) | direct Anthropic API |
| `codex-api` | `direct_api` | `api_key` (`OPENAI_API_KEY`) | direct OpenAI/Codex-family API |
| `gemini-api` | `direct_api` | `vertex_adc` first, `GEMINI_API_KEY` fallback | canonical Gemini direct path |
| `claude` | `cli_agent` | `cli_cached_login` | Claude Code / CLI runtime |
| `codex` | `cli_agent` | `cli_cached_login` | Codex CLI runtime |
| `gemini` | `cli_agent` | `cli_cached_login` | Gemini CLI runtime |
| `kimi` | `cli_agent` | `cli_cached_login` | Kimi CLI runtime |

## Direct API Policy

- `claude-api:<model>`
  - direct Anthropic path
  - requires `ANTHROPIC_API_KEY`
- `codex-api:<model>` or `openai:<model>`
  - direct OpenAI path
  - requires `OPENAI_API_KEY`
- `gemini-api:<model>` or legacy `gemini:<model>`
  - resolves auth in this order:
    1. `GOOGLE_CLOUD_PROJECT` + ADC
    2. `GEMINI_API_KEY`
    3. actionable error

`gemini-api` Vertex path uses:

- `GOOGLE_CLOUD_PROJECT`
- `GOOGLE_CLOUD_LOCATION` default `global`
- `gcloud auth application-default login`

## CLI Agent Policy

- CLI runtimes are not direct API providers.
- auth is handled by the CLI itself.
- MASC treats cached CLI login as a runtime concern, not a provider concern.

Current canonical CLI contracts:

- `claude`
  - machine-readable JSON stdout
  - prompt via CLI-native path
- `codex`
  - machine-readable JSON stdout
  - prompt via CLI-native path
- `gemini`
  - `--output-format json`
  - prompt via `-p`
  - stdout JSON `response` is the worker output
  - stderr is non-authoritative noise/logging only
- `kimi`
  - `--output-format stream-json`
  - prompt via `-p`
  - `--print`
  - stdout is JSON Lines (`assistant` and `tool` role lines)
  - stderr is non-authoritative noise/logging only

## Default Swarm Policy

- default worker substrate: managed by cascade
- `claude`, `codex`, `gemini`, `kimi` are explicit opt-in workers
- direct API adapters are for:
  - keeper/always-on/MDAL/direct reasoning paths
  - not the default swarm substrate

## Compatibility

- legacy direct aliases remain supported:
  - `anthropic:<model>` -> `claude-api`
  - `google:<model>` -> `gemini-api`
  - `gemini:<model>` -> `gemini-api`
- CLI names remain simple:
  - `claude`
  - `codex`
  - `gemini`
  - `kimi`

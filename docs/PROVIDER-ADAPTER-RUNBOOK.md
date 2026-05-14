---
status: runbook
last_verified: 2026-05-14
code_refs:
  - lib/provider_adapter.ml
  - lib/provider_adapter.mli
  - docs/PROVIDER-ADAPTER-REMOVAL-PLAN.md
  - scripts/lint/provider-adapter-removal-ratchet.sh
---

# Provider Adapter Runbook

이 문서는 현재 `MASC` 호환성 상태를 설명한다. Provider identity,
base URL, request path, auth env, capabilities는 OAS
`Provider_runtime_binding` / `Provider_registry`가 SSOT다.
`Provider_adapter` 내부 catalog, runtime overlay, provider-specific env
fallback을 새로 추가하지 않는다.

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
| `ollama` | `local` | `none` | `OLLAMA_DEFAULT_MODEL` env; bare `ollama` requires explicit model |
| `glm` | `direct_api` | `api_key` (`ZAI_API_KEY`) | current Z.ai direct path |
| `glm-coding` | `direct_api` | `api_key` (`ZAI_API_KEY`) | Z.ai coding-plan direct path |
| `claude` | `direct_api` | `api_key` (`ANTHROPIC_API_KEY`) | direct Anthropic API |
| `gemini` | `direct_api` | `vertex_adc` first, `GEMINI_API_KEY` fallback | canonical Gemini direct path |
| `kimi` | `direct_api` | `api_key` (`KIMI_API_KEY`) | direct Kimi API from OAS registry |
| `openrouter` | `direct_api` | `api_key` (`OPENROUTER_API_KEY`) | OpenRouter aggregation |
| `claude_code` | `cli_agent` | `cli_cached_login` | Claude Code / CLI runtime |
| `codex_cli` | `cli_agent` | `cli_cached_login` | Codex CLI runtime |
| `gemini_cli` | `cli_agent` | `cli_cached_login` | Gemini CLI runtime |
| `kimi_cli` | `cli_agent` | `cli_cached_login` | Kimi CLI runtime |

## Voice Adapters

| Canonical name | Runtime | Auth | Aliases | Notes |
|---|---|---|---|---|
| `voice-openai-compat` | `direct_api` | `none` | `openai_compat`, `openai`, `railway-elevenlabs-proxy` | OpenAI-compatible TTS endpoint; endpoint-specific `api_key_env` can override auth when required |
| `elevenlabs-direct` | `direct_api` | `api_key` (`ELEVENLABS_API_KEY`) | `elevenlabs`, `tts-elevenlabs` | ElevenLabs direct TTS |
| `voice-mcp` | `local` | `none` | `voice_mcp`, `mcp`, `local-voice-mcp` | Local voice MCP bridge |

## Custom Endpoint

`custom:model@url` 형식으로 임의의 OpenAI-compatible 엔드포인트를 지정할 수 있다. `direct_adapters`에 등록되지는 않지만, `custom` prefix는 별도 direct adapter 등록 없이도 항상 resolve되며 `local`/self-hosted runtime으로 취급된다.

## Direct API Policy

- `claude:<model>`
  - direct Anthropic path
  - requires `ANTHROPIC_API_KEY`
- `openrouter:<model>`
  - OpenRouter aggregation path
  - requires `OPENROUTER_API_KEY`
- `gemini:<model>`
  - resolves auth in this order:
    1. `GOOGLE_CLOUD_PROJECT` + ADC
    2. `GEMINI_API_KEY`
    3. actionable error
- `kimi:<model>`
  - direct Kimi API path from OAS registry
  - requires `KIMI_API_KEY`
- `glm:<model>`
  - Z.ai general direct path
  - requires `ZAI_API_KEY`
- `glm-coding:<model>`
  - Z.ai coding-plan direct path
  - requires `ZAI_API_KEY`

`gemini` Vertex path uses:

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
- `claude_code`, `codex_cli`, `gemini_cli`, `kimi_cli` are explicit opt-in workers
- direct API adapters are for:
  - keeper/always-on/MDAL/direct reasoning paths
  - not the default swarm substrate

## Compatibility

- provider labels are resolved through OAS registry/binding aliases first.
- historical display labels such as `kimi-api` are normalized only as
  compatibility labels; they do not carry separate endpoint or auth truth in
  MASC.
- CLI names use the registry ids:
  - `claude_code`
  - `codex_cli`
  - `gemini_cli`
  - `kimi_cli`

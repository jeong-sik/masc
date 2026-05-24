---
rfc-id: RFC-0176
title: OAS vendor-purge migration — consume agent_sdk 0.197.0
status: Implemented
authors: Claude (Vincent)
created: 2026-05-24
implemented: 2026-05-24 (PR #18262)
related: OAS RFC-0001 (PR #1727, #1729, #1731), OAS PR #1737 (version bump)
renumber-note: Originally written as RFC-0174 in PR #18262; renumbered to RFC-0176 here to resolve numbering collision with the pre-existing RFC-0174-dashboard-substring-classifier-to-typed.md. The commit history references for the original PR retain the RFC-0174 string as historical record.
---

# RFC-0176 OAS vendor-purge migration

## 1. Problem

OAS RFC-0001 (PRs #1727 / #1729 / #1731) renamed the entire public SDK identifier surface:
- Variant constructors (`Anthropic → Provider_a`, `Kimi → Provider_c`, `OpenAI_compat → Provider_d_compat`, `Claude_code → Cli_tool_d`, etc.)
- Module file renames (`backend_anthropic.{ml,mli} → backend_provider_a.{ml,mli}`, etc.)
- Env vars (`ANTHROPIC_API_KEY → PROVIDER_A_API_KEY`, etc.)

masc-mcp consumes `agent_sdk` via opam pin and has ~115 SDK call sites referencing the old names. They must migrate atomically with the new SDK version.

OAS PR #1737 bumps `agent_sdk` to `0.197.0` (gated, pending merge). This RFC's PR is sequenced after #1737 merges.

## 2. Decision

### Provider_config / Provider_kind variant migration

| Old | New |
|-----|-----|
| `Llm_provider.Provider_config.OpenAI_compat` (32 sites) | `Llm_provider.Provider_config.Provider_d_compat` |
| `Llm_provider.Provider_config.Claude_code` (11) | `Llm_provider.Provider_config.Cli_tool_d` |
| `Llm_provider.Provider_config.Codex_cli` (8) | `Llm_provider.Provider_config.Cli_tool_a` |
| `Llm_provider.Provider_config.Kimi_cli` (8) | `Llm_provider.Provider_config.Cli_tool_c` |
| `Llm_provider.Provider_config.Glm` (7) | `Llm_provider.Provider_config.Provider_k` |
| `Llm_provider.Provider_config.Gemini_cli` (4) | `Llm_provider.Provider_config.Cli_tool_b` |
| `Llm_provider.Provider_config.Kimi` (4) | `Llm_provider.Provider_config.Provider_c` |
| `Llm_provider.Provider_config.DashScope` (1) | `Llm_provider.Provider_config.Provider_h` |
| `Llm_provider.Provider_config.Anthropic` (1) | `Llm_provider.Provider_config.Provider_a` |
| `Llm_provider.Provider_kind.{OpenAI_compat, Kimi_cli, Anthropic}` (12) | corresponding `Provider_d_compat / Cli_tool_c / Provider_a` |

### Bare match patterns

`match kind with | Anthropic | Kimi -> ...` style — same mapping applied as bare identifiers (~210 sites including all `.ml` / `.mli` plus `.inc` test stanza).

### Module-level imports

| Old | New |
|-----|-----|
| `Llm_provider.Transport_claude_code` | `Llm_provider.Transport_cli_tool_d` |
| `Llm_provider.Transport_gemini_cli` | `Llm_provider.Transport_cli_tool_b` |
| `Llm_provider.Transport_codex_cli` | `Llm_provider.Transport_cli_tool_a` |
| `Llm_provider.Api_common` | preserved |

### OAS facade module variants

| Old | New |
|-----|-----|
| `Agent_sdk.Provider.Anthropic_messages` | `Agent_sdk.Provider.Provider_a_messages` |
| `Agent_sdk.Provider.Openai_chat_completions` | preserved (same name in new SDK) |
| `Runtime_binding.Custom_openai_compat` | `Runtime_binding.Custom_provider_d_compat` |
| `Custom_anthropic` (if any) | `Custom_provider_a` |

### dune-project

`(agent_sdk (>= 0.196.16))` → `(agent_sdk (>= 0.197.0))` — forces opam to refresh to the post-purge SDK.

## 3. Out of scope

- **masc-mcp 자체 vendor-coupled enum** (`Phonebook.Zai_glm`, `Phonebook.Qwen`, `cascade_phonebook_types.Anthropic_http`, dashboard string `"provider_a-cli"`, etc.) — separate RFC. These are internal classifications that map *to* the SDK; the mapping is updated here (e.g., `Zai_glm -> Llm_provider.Provider_config.Provider_k`), but the masc-mcp side identifiers are preserved pending a future audit.
- **opam state cleanup** for local development — operator responsibility (`opam pin remove agent_sdk && opam pin add agent_sdk git+https://github.com/jeong-sik/oas.git --yes` after #1737 merges).

## 4. Verification plan

- Build via CI fresh opam env (this RFC's PR). Local verification is blocked by opam pin source cache corruption — CI builds fresh.
- `find lib bin test -type f \( -name '*.ml' -o -name '*.mli' \) | xargs grep -E 'Llm_provider\.(Provider_config|Provider_kind)\.(Anthropic|Kimi|OpenAI_compat|Claude_code|Codex_cli|Gemini_cli|Kimi_cli|Glm|DashScope)\b|Llm_provider\.Transport_(claude_code|codex_cli|gemini_cli|kimi_cli)\b|Anthropic_messages\b|Custom_(openai_compat|anthropic)\b'` returns 0.

## 5. Workaround-rejection self-check

This PR is pure identifier rename to match the new SDK API. No catch-all, no string classifier added, no cap/cooldown/dedup, no test backdoor.

All 7 signatures: NO.

## 6. Sequencing

1. OAS PR #1737 (version 0.197.0) merges → opam-repository auto-publish via release-please tag.
2. This PR's CI fetches fresh agent_sdk.0.197.0 → caller migration validates.
3. masc-mcp operator runs `opam pin remove agent_sdk; opam install masc-mcp` for local development to pick up the new SDK.

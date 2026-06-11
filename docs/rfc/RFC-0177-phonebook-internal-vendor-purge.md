---
rfc-id: RFC-0177
title: Phonebook internal vendor-coupled enum purge
status: Draft
authors: Claude (Vincent)
created: 2026-05-24
related: RFC-0176 (OAS migration), RFC-0174-dashboard-substring-classifier-to-typed
---

# RFC-0177 Phonebook internal vendor-coupled enum purge

## 1. Problem

RFC-0176 migrated the OAS SDK boundary (Provider_config, Provider_kind, Transport modules). The migration explicitly deferred masc's *internal* vendor-coupled enums:

- `runtime_server_flavor` variants: `Zai_glm`, `Qwen`, `Openai`, `Deep_seek`, `Anthropic_http`
- These are masc's own classification of wire-format flavors, separate from the SDK's Provider_kind.

The outbound `flavor_to_string` was already updated to emit purged wire-strings (`"provider_d"`, `"deepseek"`, `"zai-provider_k"`, `"provider_h"`), but the OCaml constructor names retained the vendor brand.

Per user direction "전부 폭파 — aggregator 포함", this RFC closes the internal-side enum names.

## 2. Decision

### Variant renames (runtime_phonebook_types.ml)

| Old | New | Vendor mapping |
|-----|-----|----------------|
| `Anthropic_http` (4 sites) | `Provider_a_http` | Anthropic = Provider_a |
| `Anthropic_messages_compat` (if any) | `Provider_a_messages_compat` | same |
| `Zai_glm` (13 sites) | `Provider_k_zai` | Z.AI/GLM = Provider_k |
| `Deep_seek` (14 sites) | `DeepSeek_wire` | DeepSeek direct |
| `Openai` (17 sites) | `Provider_d_wire` | OpenAI canonical wire = Provider_d |
| `Qwen` (27 sites) | `Provider_h_wire` | Qwen/DashScope = Provider_h |

### Preserved (technical / non-vendor)

- `Llama_cpp` — open-source serving framework (Meta's llama.cpp project)
- `Ollama` — open-source serving framework
- `Vllm` — open-source serving framework

These are *serving infrastructure*, not vendor brands. Same rationale as OAS RFC-0001 §3 (Ollama variant preservation).

### Wire-string mapping table

`flavor_to_string` / `flavor_of_string` already emit/parse purged wire-strings (`"provider_d"`, `"deepseek"`, `"zai-provider_k"`, `"provider_h"`). This RFC does not touch the wire format — only the OCaml constructor names. Operators reading TOML configs see no change.

## 3. Out of scope

- Other masc internal vendor references not in `runtime_phonebook_types.ml` (e.g., string fixtures `"anthropic"` / `"openai"` in tests, comment references) — future audit.
- Dashboard string fixtures (`"provider_a-cli"`, `"provider_f-cli"`) — separate dashboard sweep.

## 4. Verification

- ~75 OCaml constructor sites renamed across `lib/runtime/`, `lib/keeper/`, `lib/dashboard/`, related test files.
- Static residue check:
  ```
  find lib bin test -type f \( -name '*.ml' -o -name '*.mli' \) | xargs grep -E '\b(Zai_glm|Qwen|Anthropic_http|Anthropic_messages_compat|Deep_seek|\bOpenai\b)\b'
  ```
  returns 0.
- Local build verification blocked by opam pin source cache corruption (carried over from RFC-0176 — operator action pending). CI fresh opam env validates.

## 5. Workaround-rejection self-check

Pure constructor rename. No catch-all, no string classifier, no cap/cooldown/dedup, no test backdoor. All 7 signatures: NO.

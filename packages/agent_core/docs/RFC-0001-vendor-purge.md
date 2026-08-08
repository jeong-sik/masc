# OAS RFC-0001 Big-bang vendor name purge (SDK boundary)

| | |
|---|---|
| Status | **Withdrawn (superseded by RFC-OAS-023)** |
| Withdrawn | 2026-05-26 |
| Superseded by | [RFC-OAS-023](rfc/RFC-OAS-023-capability-axis-reshape.md) capability axis reshape |
| Related (masc-mcp) | RFC-0165 ~ RFC-0173 client-agnostic family |
| Scope | All `lib/`, `bin/`, `test/` OCaml files |
| Repo | yousleepwhen/oas |

## 0. Withdrawal notice (2026-05-26)

본 RFC 는 RFC-OAS-023 §7.1 에 의해 **명명 정책 부분이 역방향으로 supersede** 되었다.

사유 ([feedback_vendor_brand_substitution_is_encryption_not_abstraction], 2026-05-24):

> Vendor brand → 알파벳 부호 1:1 substitution 은 abstraction 아닌 *암호화*.

RFC-0001 이 정의한 14×N 부호 매핑은 *암호화* 였다는 자기 평가에 따라 폐기. RFC-OAS-023 의 대안: hybrid naming (model=brand, transport=wire-protocol).

**보존되는 동기**: RFC-0001 의 *다른* 동기 (SDK boundary 폐쇄, masc-mcp 일관성, single consumer environment) 는 RFC-OAS-023 에 흡수.

향후 *역사적 참고* 로만 보존.

## 1. Problem

masc-mcp RFC-0173 closed all vendor name references *except* 209 files that called into `agent_sdk.llm_provider` SDK closed-sum variant constructors. OAS is the SDK source. This RFC closes the SDK boundary.

User direction (from masc-mcp session):

> "OAS 가 그쪽이니까 같이 폭파에 동참하자"
> "전체 폭파 . 어차피 레거시 지원 안할거임"

OAS has one external consumer (masc-mcp), under the same operator's control. Fork-free renaming is feasible.

## 2. Decision

### Variant constructor renaming

| Original | New |
|----------|-----|
| `Anthropic` | `Provider_a` |
| `Moonshot` | `Provider_b` |
| `Kimi` | `Provider_c` |
| `OpenAI_compat` | `Provider_d_compat` |
| `OpenAI` (if any) | `Provider_d` |
| `Gemini` | `Provider_f` |
| `DeepSeek` | `DeepSeek` |
| `DashScope` | `Provider_h` |
| `Glm` / `GLM` | `Provider_k` |
| `Claude_code` | `Cli_tool_d` |
| `Gemini_cli` | `Cli_tool_b` |
| `Kimi_cli` | `Cli_tool_c` |
| `Codex_cli` | `Cli_tool_a` |
| `Anthropic_messages` (request kind) | `Provider_a_messages` |
| `Gemini_3_1`, `Gemini_3`, `Gemini_2_5`, `Gemini_other` (model variants) | `Provider_f_3_1`, etc. |
| `Claude_opus_4`, `Claude_sonnet_4`, `Claude_haiku_4` | `Agent_llm_a_opus_4`, etc. |
| `Kimi_for_coding`, `Kimi_k2` | `Provider_c_for_coding`, `Provider_c_k2` |
| `Deepseek_v4_flash`, `Deepseek_v4_pro` | `Deepseek_v4_flash`, `Deepseek_v4_pro` |
| `Qwen3` (capabilities static_model_route) | `Provider_h_3` |
| `Mistral_large`, `Mistral_small` | `Provider_j_large`, `Provider_j_small` |
| `Glm_quota_exceeded`, `Glm_rate_limited`, `Glm_auth_error`, `Glm_server_error`, `Glm_invalid_request` (backend_provider_k error variants) | `Provider_k_quota_exceeded`, `Provider_k_rate_limited`, `Provider_k_auth_error`, `Provider_k_server_error`, `Provider_k_invalid_request` |
| `Glm_api_error` (exception) | `Provider_k_api_error` |
| `glm_error_class`, `glm_error` (types) | `provider_k_error_class`, `provider_k_error` |
| `classify_glm_error`, `http_code_of_glm_error_class`, `glm_messages_of_message`, `glm_auto_models`, `glm_coding_auto_models` (functions) | `classify_provider_k_error`, `http_code_of_provider_k_error_class`, `provider_k_messages_of_message`, `provider_k_auto_models`, `provider_k_coding_auto_models` |

### Model id string renames (Qwen family — boundary-miss closure)

| Original | New |
|----------|-----|
| `qwen3.5-35b`, `qwen3.5-35b-a3b`, `qwen3.5-35b-a3b-nvfp4` | `provider_h-3.5-35b`, `provider_h-3.5-35b-a3b`, `provider_h-3.5-35b-a3b-nvfp4` |
| `qwen3.5`, `qwen3.5:9b`, `qwen3:8b` | `provider_h-3.5`, `provider_h-3.5:9b`, `provider_h-3:8b` |
| `"qwen3"` (string prefix), `Qwen3.5-35B`, `Qwen3.5-35B-A3B`, `Qwen3.x`, `Qwen3.5` (comments) | `"provider_h-3"`, `Provider_h-3.5-35B`, `Provider_h-3.5-35B-A3B`, `Provider_h-3.x`, `Provider_h-3.5` |

These were missed by the initial `\bqwen\b` perl regex pass because `qwen` followed by a digit (`qwen3`) has no word boundary — `\b` requires word-to-non-word transition, and `3` is `\w`. Explicit substring patterns close the gap.

### Vendor letter assignment (extended in §3-promotion sweep)

| Letter | Vendor | Category |
|--------|--------|----------|
| `a` | Anthropic | LLM provider |
| `b` | Moonshot | LLM provider |
| `c` | Kimi | LLM provider |
| `d` | OpenAI | LLM provider |
| `e` | xAI | LLM provider |
| `f` | Google (Gemini + Gemma + Vertex) | LLM provider |
| `g` | DeepSeek | LLM provider |
| `h` | Qwen / DashScope | LLM provider |
| `i` | Groq | Inference |
| `j` | Mistral | LLM provider |
| `k` | Glm (Zhipu AI) | LLM provider |
| `l` | Nemotron | LLM provider |
| `m` | **Cohere** (new) | LLM provider |
| `n` | **Meta** (new) | Open-weight provider (Llama family) |
| `o` | **OpenRouter** (new) | Aggregator (identifier only — URL preserved) |

### Constructor renames (§3-promotion follow-up)

| Original | New |
|----------|-----|
| `Gpt_5`, `Gpt_4_1`, `Gpt_4o` | `Provider_d_5`, `Provider_d_4_1`, `Provider_d_4o` |
| `Llama_4` | `Provider_n_4` |
| `Gemma_4 of { has_large_audio : bool }` | `Provider_f_gemma_4 of { has_large_audio : bool }` |
| `Grok` | `Provider_e_grok` |
| `Command` | `Provider_m_command` |
| `Llama_server` (future-variant comment) | `Provider_n_server` |

### Model id strings (§3-promotion follow-up)

| Family | Original | New |
|--------|----------|-----|
| GPT (OpenAI) | `gpt-4`, `gpt-4o`, `gpt-4o-mini`, `gpt-4.1`, `gpt-5`, `gpt-5.1`, `gpt-5.2`, `gpt-5.3-agent_code{,-spark}`, `gpt-5.4{,-mini}`, `gpt-5.5`, `gpt-image` | `model-d-*` |
| Llama (Meta) | `llama-3.1-70b`, `llama-3.3-70b`, `llama-4-scout`, `llama-4-maverick`, `llama-70b`, `llama.context_length`, `"llama"`, `"ollama/llama3"`, `"ollama/llama"` | `model-n-*` / `provider_n*` |
| Gemma (Google) | `gemma-*`, `"gemma"`, `gemma_4_has_large_audio` | `model-f-gemma-*`, `"provider_f_gemma"`, `provider_f_gemma_4_has_large_audio` |
| Grok (xAI) | `grok-*`, `"grok"`, `~prefix:"grok"` | `model-e-grok-*`, `"provider_e_grok"`, `~prefix:"model-e-grok"` |
| Qwen underscore (boundary miss) | `qwen3_5` | `provider_h_3_5` |
| Meta as owned_by | `"owned_by":"meta"`, `"owned_by", \`String "meta"` | `"owned_by":"provider_n"`, `"owned_by", \`String "provider_n"` |

### Aggregator / Cloud identifiers

- `openrouter` / `OpenRouter` (OCaml identifier) → `provider_o_router` / `Provider_o_router`
- `Vertex AI` (comment) → `Provider_f cloud`

### File renames

17 modules renamed via `git mv`:

- `api_anthropic.{ml,mli}` → `api_provider_a.{ml,mli}`
- `api_openai.{ml,mli}` → `api_provider_d.{ml,mli}`
- `backend_anthropic.{ml,mli}` → `backend_provider_a.{ml,mli}`
- `backend_openai{,_parse,_request,_serialize}.{ml,mli}` → `backend_provider_d{,_parse,_request,_serialize}.{ml,mli}`
- `backend_gemini.{ml,mli}` → `backend_provider_f.{ml,mli}`
- `backend_glm.{ml,mli}` → `backend_provider_k.{ml,mli}`
- `transport_codex_cli.{ml,mli}` → `transport_cli_tool_a.{ml,mli}`
- `transport_gemini_cli.{ml,mli}` → `transport_cli_tool_b.{ml,mli}`
- `transport_kimi_cli.{ml,mli}` → `transport_cli_tool_c.{ml,mli}`
- `transport_claude_code.{ml,mli}` → `transport_cli_tool_d.{ml,mli}`
- `transport_openai_compat.{ml,mli}` → `transport_provider_d_compat.{ml,mli}`
- `test_gemini_edge_cases.ml` → `test_provider_f_edge_cases.ml`
- `test_backend_gemini.ml` → `test_backend_provider_f.ml`
- `test_streaming_openai.ml` → `test_streaming_provider_d.ml`

Module references updated repo-wide; `test/dune` test list updated.

### Function/value renaming

- `glm_capabilities` → `provider_k_capabilities` (with `.mli` sync)

### Env var renaming (operator action required)

| Original | New |
|----------|-----|
| `ANTHROPIC_API_KEY`, `ANTHROPIC_DEFAULT_MODEL` | `PROVIDER_A_API_KEY`, `PROVIDER_A_DEFAULT_MODEL` |
| `GEMINI_API_KEY`, `GEMINI_DEFAULT_MODEL` | `PROVIDER_F_API_KEY`, `PROVIDER_F_DEFAULT_MODEL` |
| `KIMI_API_KEY`, `KIMI_BASE_URL`, `KIMI_DEFAULT_MODEL` | `PROVIDER_C_*` |
| `OPENAI_API_KEY`, `OPENAI_DEFAULT_MODEL` | `PROVIDER_D_*` |
| `MOONSHOT_API_KEY` | `PROVIDER_B_API_KEY` |
| `DEEPSEEK_API_KEY` | `DEEPSEEK_API_KEY` |
| `GLM_API_KEY` | `PROVIDER_K_API_KEY` |
| `DASHSCOPE_API_KEY` | `PROVIDER_H_API_KEY` |
| `CODEX_API_KEY` | `CLI_TOOL_A_API_KEY` |

**Operator action**: update `.zshenv` to re-export with new names. Old env vars are no longer read.

## 3. Intentionally preserved (RFC-0001 §3)

| Surface | Reason |
|---|---|
| `agent_llm_a_path = "claude"` (transport_cli_tool_d.ml) | External OS binary name. `claude` binary is the actual CLI tool installed on the operator's system. |
| `agent_code_path = "codex"` (transport_cli_tool_a.ml) | Same — external `codex` binary. |
| `provider_f_path = "gemini"` (transport_cli_tool_b.ml) | Same — external `gemini` binary. |
| `provider_c_path = "kimi"` (transport_cli_tool_c.ml) | Same — external `kimi` binary. |
| `~name:"claude"`, `~name:"codex"`, `~name:"gemini"`, `~name:"kimi"` (log labels in subprocess transport) | Same as binary path — operator-facing label that matches the actual binary. |
| `CODEX_COMPANION_SESSION_ID` env var (scrubbed) | External Codex CLI's own env var, scrubbed by transport before subprocess exec. Not OAS-defined. |
| `Ollama` variant (provider_kind) | LLM serving framework, not vendor — same rationale as masc-mcp RFC-0168~0173. |
| `llama-server`, `llama.cpp` references | External LLM serving infrastructure (Meta's `llama.cpp` project + its bundled `llama-server` binary). Operator-installed software, same boundary as `claude`/`codex` binaries. |
| `https://openrouter.ai/api/v1` URL | Real external OpenRouter service endpoint. Changing this string breaks live HTTP requests to the aggregator — same boundary as runtime binary paths. The OCaml identifier `openrouter` was renamed to `provider_o_router`; the URL string itself stays. |
| `https://generativelanguage.googleapis.com` URL | Real external Google AI endpoint. Same rationale as above. |
| `"Command"` text in test fixtures (`description = "Command"`, `goal = "Command test"`) | Generic English, not vendor reference. |
| `"Command-line interface"` prose in `bin/oas_cli.ml` | Standard CLI term. |
| Comment references to original vendor names | None — all rewritten. |

These 4 binary path + 12 spawn-name occurrences plus the external HTTP endpoint URLs are the technical boundary: the SDK has to name the actual binaries and services it talks to. Everything else — including open-weight model families (Llama, Gemma) and aggregator identifiers (`openrouter`) — was promoted from §3 to §2 in the §3-promotion follow-up sweep, per user direction "전부 폭파 — aggregator 포함".

## 4. Verification

- `dune build lib` clean (after both initial sweep and Qwen/Mistral/Glm boundary-miss closure).
- `dune build bin` clean.
- `dune build test` clean (including main's PR #1726 new test files which required follow-up sweep for `Constants.{Anthropic,Gemini}` modules and `gemini25_*` identifiers).
- `find lib bin test -type f \( -name '*.ml' -o -name '*.mli' \) | xargs grep -E 'anthropic|kimi|gemini|moonshot|codex|claude|dashscope|qwen3|Mistral_(large|small)|Glm_(quota|rate|auth|server|invalid|api)_'` returns only the §3 preserved occurrences (binary path + spawn names + open-weight model families).

## 5. Downstream consumer migration

masc-mcp will receive a follow-up PR that:
1. Updates the opam pin or version in `dune-project` to consume this OAS release.
2. Rewrites the remaining 209 `Llm_provider.Provider_config.{Kimi, Claude_code, ...}` call sites to use the new `{Provider_c, Cli_tool_d, ...}` constructors.

That follow-up is RFC-0174 in masc-mcp's RFC sequence.

## 6. Workaround-rejection self-check

This RFC removes vendor namespace; it does not add code paths.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO.
3. "PR #N fixed K of M sites" — NO (sweeps the entire OAS surface in one PR; 16 occurrences in §3 are the external OS boundary).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 7. Breaking change

This is a **major version bump** (0.196.x → 0.197.0 or 1.0.0 by operator preference). Every downstream consumer must migrate. Only masc-mcp is known to depend on `agent_sdk.llm_provider` — handled by RFC-0174.

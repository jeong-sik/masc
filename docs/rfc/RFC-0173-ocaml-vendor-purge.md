# RFC-0173 OCaml lib/bin/test vendor purge (identifier + string literal)

| | |
|---|---|
| Status | Draft |
| Related | RFC-0165 ~ RFC-0172 (client-agnostic family) |
| Scope | 241 `.ml`/`.mli` files in `lib/`, `bin/`, `test/` |
| Repos | masc |

## 1. Problem

RFC-0172 deferred OCaml because identifier-level rewrite needs hyphen-free mappings and SDK API call sites must be protected. This RFC closes that residue.

## 2. Decision

Apply hyphen-free underscore mapping (no `-` in any replacement, so OCaml identifier validity is preserved) across lowercase occurrences only. Capitalized SDK variant constructors are protected by case-sensitive sed.

| Original (lowercase) | Replacement |
|---|---|
| `anthropic` | `provider_a` |
| `moonshot` | `provider_b` |
| `kimi` (word) | `provider_c` |
| `openai` (word) | `provider_d` |
| `xai` (word) | `provider_e` |
| `gemini` | `provider_f` |
| `deepseek` | `deepseek` |
| `qwen` (word) | `provider_h` |
| `groq` (word) | `provider_i` |
| `mistral` (word) | `provider_j` |
| `glm` (word) | `provider_k` |
| `nemotron` | `provider_l` |
| `codex` (word) | `agent_code` |
| `claude` (word) | `agent_llm_a` |
| `codex_cli` | `cli_tool_a` |
| `gemini_cli` | `cli_tool_b` |
| `kimi_cli` | `cli_tool_c` |
| `claude_code` | `cli_tool_d` |
| `claude-3-5-sonnet-...`, `claude-sonnet-X.Y` | `model-a-sonnet` |
| `claude-haiku-X-Y` | `model-a-haiku` |
| `claude-opus-X.Y` | `model-a-opus` |
| `kimi-k2.6:cloud` etc. | `model-c:cloud` etc. |
| `kimi-for-coding` | `model-c-coding` |
| `gpt-X.Y` family | `model-d`, `model-d-mini`, `model-d-spark` |
| `grok-X` | `model-e` |
| `llama-3.X-NNb` | `model-llama-large` |

## 3. SDK module name reverts (RFC-0173 §3)

The initial sweep converted these external SDK module references and was immediately reverted:

| Reverted to | Reason |
|---|---|
| `Llm_provider.Transport_claude_code` | `agent_sdk.llm_provider` opam module name |
| `Llm_provider.Transport_gemini_cli` | same |
| `Llm_provider.Transport_codex_cli` | same |
| `Llm_provider.Transport_kimi_cli` | same |

## 4. Intentionally preserved

| Surface | Reason |
|---|---|
| `Llm_provider.Provider_config.{Kimi,Kimi_cli,Claude_code,Codex_cli,Gemini_cli,Anthropic,OpenAI,DeepSeek,Qwen,Mistral,Nemotron,Moonshot,Llama_cpp,Ollama,Vllm,Zai_glm}` etc. | External SDK closed-sum variant constructors (capitalized). Renaming them = SDK fork. |
| `Llm_provider.Transport_*` modules | External SDK module exports. |
| `code.claude.com` URLs in comments | Anthropic official documentation references. |
| `Ollama`, `ollama` (LLM serving framework) | Not a vendor — already kept by RFC-0168~0172. |
| `keeper_identity*` `'llama'` literal | Animal name in keeper nickname pool. |

These 209 files retain references because they ultimately call into the external SDK closed-sum variants. Removing the SDK boundary is out of scope for masc.

## 5. Verification

- `dune build lib/ bin/` exit code matches origin/main baseline (`Credits_dashboard` Unbound + 11 pre-existing partial-match warnings on `Agent (InputRequired _)`). The sweep introduces **zero additional errors**.
- `dune build test/` matches the same baseline.
- `pnpm run typecheck` clean.
- `find lib bin test -type f \( -name '*.ml' -o -name '*.mli' \) | xargs grep -l ...` returns 209 files, all matching the §4 preserved categories (SDK API calls).

## 6. Workaround-rejection self-check

This RFC rewrites identifiers and string literals. It does not add code paths.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO.
3. "PR #N fixed K of M sites" — NO (sweeps the entire 241-file OCaml roster; the remaining 209 are SDK API calls that cannot be renamed without forking the SDK; the carve-out reason is documented in §4).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 7. Trade-off acknowledgement

This is the technical boundary of vendor purge within masc. Further removal would require:

1. Forking `agent_sdk.llm_provider` and renaming its variant constructors, OR
2. Wrapping every SDK call site with a local typed adapter (lib/sdk_facade with vendor-agnostic variant names).

Option 2 is the structurally clean follow-up (a future RFC-0174 if user pursues it). Option 1 is heavier and out of scope.

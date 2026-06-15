# RFC-0172 Big-bang vendor purge across docs, audits, RFCs, design-system, tests

| | |
|---|---|
| Status | Draft |
| Related | RFC-0165 / 0166 / 0167 / 0168 / 0169 / 0170 / 0171 (client-agnostic family) |
| Scope | 270 files: `docs/**/*.md`, `docs/**/*.{csv,toml,inc,tla,cfg,html}`, `dashboard/src/**/*.test.{ts,tsx}`, `dashboard/design-system/{audits,RFC,CHANGELOG,README,SKILL}.md` |
| Repos | masc |
| Out of scope | `test/` OCaml fixtures (168 files reverted — see §3) |

## 1. Problem

After RFC-0165~0171 cleared client/provider names from production code (lib/, bin/, dashboard/src production code) and from design canvas mocks, the remaining occurrences live in:

- `docs/` (history, RFC bodies, audit reports, runbooks, TLA+ specs) — 234 files
- `dashboard/src/**/*.test.{ts,tsx}` — 49 files
- `dashboard/design-system/{audits,RFC,CHANGELOG.md,README.md,SKILL.md}` — 16 files
- `test/` OCaml fixtures — 200+ files

Operator memory `feedback-big-bang-refactor-preference`: carve-outs (preserving "historical citation") were declined. This RFC sweeps the entire residue in one PR.

## 2. Decision

Apply the RFC-0171 mapping table (provider-a..provider-l, cli-tool-a..cli-tool-d, model-a-sonnet, model-a-haiku, model-c, model-d, model-e, model-llama, model-mistral, agent-llm-a, agent-code) consistently across all text-content files.

Mapping target set (perl word-boundary, case-sensitive, both lowercase and capitalized forms):

| Original | Replacement |
|----------|-------------|
| `anthropic` / `Anthropic` / `ANTHROPIC` | `provider-a` / `Provider-A` / `PROVIDER-A` |
| `moonshot` / `Moonshot` / `MOONSHOT` | `provider-b` / `Provider-B` / `PROVIDER-B` |
| `kimi` / `Kimi` / `KIMI` (word) | `provider-c` / `Provider-C` / `PROVIDER-C` |
| `openai` / `OpenAI` (word) | `provider-d` / `Provider-D` |
| `xai` / `xAI` (word) | `provider-e` / `Provider-E` |
| `gemini` / `Gemini` / `GEMINI` | `provider-f` / `Provider-F` / `PROVIDER-F` |
| `deepseek` / `DeepSeek` | `deepseek` / `DeepSeek` |
| `qwen` / `Qwen` (word) | `provider-h` / `Provider-H` |
| `groq` / `Groq` (word) | `provider-i` / `Provider-I` |
| `mistral` / `Mistral` (word) | `provider-j` / `Provider-J` |
| `glm` / `GLM` (word) | `provider-k` / `Provider-K` |
| `nemotron` / `Nemotron` | `provider-l` / `Provider-L` |
| `codex` / `Codex` / `CODEX` (word) | `agent-code` / `Agent-Code` / `AGENT-CODE` |
| `claude` / `Claude` / `CLAUDE` (word, with path-prefix guard) | `agent-llm-a` / `Agent-LLM-A` / `AGENT-LLM-A` |
| `codex_cli` / `gemini_cli` / `kimi_cli` / `claude_code` | `cli-tool-a..d` |
| `Codex CLI` / `Gemini CLI` / `Claude Code` | `CLI-Tool-A..D` |
| `OAS_CLAUDE_*` / `OAS_CODEX_*` / `OAS_GEMINI_*` env vars | `OAS_CLI_TOOL_A_*` / `OAS_CLI_TOOL_B_*` / `OAS_CLI_TOOL_C_*` |
| `claude-3-5-sonnet-...`, `claude-sonnet-X.Y`, `claude-3.5` | `model-a-sonnet` |
| `claude-haiku-X-Y` | `model-a-haiku` |
| `claude-opus-X.Y` | `model-a-opus` |
| `kimi-k2.6:cloud` etc. | `model-c:cloud` etc. |
| `kimi-for-coding` | `model-c-coding` |
| `gpt-5.3-codex-spark` | `model-d-spark` |
| `gpt-4o`, `gpt-4o-mini` | `model-d`, `model-d-mini` |
| `grok-X.Y` | `model-e` |
| `llama-3.1-70b` | `model-llama-large` |

## 3. OCaml deferred to follow-up RFC

168 `.ml/.mli` files initially in scope were reverted after the sed pass produced compile failures: OCaml identifiers (function names like `test_no_tmp_gemini_in_bootstrap`, `test_agent_emoji_gemini`) embed vendor names, and the case-sensitive lowercase sed pattern converted those to `test_no_tmp_provider-f_in_bootstrap` — illegal OCaml identifier (hyphen disallowed).

OCaml purge requires a separate sed pass that distinguishes:

- **string literals** (`"claude"`, `"gemini"`) — safe to convert
- **identifiers** (function names, variant constructors, module names) — must be converted to a hyphen-free generic (e.g., `provider_f`, `provider_a`) and any cross-file references updated together

This is out of scope for RFC-0172 and deferred to RFC-0173 (planned).

## 4. Intentionally preserved (RFC-0172 §4)

| Surface | Reason |
|---------|--------|
| `~/me/planning/claude-plans/*.md`, `~/.claude/plans/*.md`, `.claude/memory/...` paths | User's own second-brain directory structure. External resource reference; renaming would break the user's environment. |
| `~/me/workspace/yousleepwhen/claude-code` | User's own workspace directory. |
| `code.claude.com/docs/...` URLs | Anthropic official documentation. External resource. |
| `CLAUDE.md` file name references | Project instruction file name (this repo's CLAUDE.md). |
| `.worktrees/claude-PK-XXXXX` worktree naming examples | User's own git worktree convention. |
| OCaml `Pk.Gemini`, `Llm_provider.Provider_config.Kimi_cli` etc. | External SDK closed-sum variant constructors in the `agent_sdk.llm_provider` opam package. |
| `Ollama`, `ollama` (LLM serving framework name) | Not a vendor — already kept by RFC-0168~0171. |
| `keeper-identity.ts:15` `'llama'` (animal) | False positive (animal name in keeper nickname pool). |

## 5. Verification

- `dune build lib/ bin/` clean (no OCaml touched).
- `dune build test/` clean (OCaml reverted).
- `pnpm run typecheck` clean.
- `cat /tmp/sweep_files.txt | xargs rg -l -i 'anthropic|\bkimi\b|...'` returns only files matching the §4 preserved categories (user paths / SDK calls / Ollama framework / animal name).

## 6. Workaround-rejection self-check

This RFC rewrites text content. It does not add code paths.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO.
3. "PR #N fixed K of M sites" — NO (sweeps the entire text content roster in one PR; OCaml deferred to RFC-0173 with explicit reason).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 7. Trade-off acknowledgement

Per operator memory `feedback-big-bang-refactor-preference`: vendor name removal is preferred over preserving historical citation accuracy in audit reports, RFC bodies, and design system docs. The cost is that future readers of RFC-0058 inventory CSV or the audit reports will see `provider-a` / `provider-b` instead of `anthropic` / `moonshot`. The original repo state remains in git history.

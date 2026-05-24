# RFC-0171 Design-canvas + ui_kits mock data vendor purge

| | |
|---|---|
| Status | Draft |
| Related | RFC-0165 / 0166 / 0167 / 0168 / 0169 / 0170 (client-agnostic family) |
| Scope | `dashboard/design-system/preview/*.{html,jsx}`, `dashboard/design-system/ui_kits/cockpit/*.{jsx,js}`, `dashboard/design-system/headless-core/anchored-thread-rail.test.ts` |
| Repos | masc-mcp |

## 1. Problem

The RFC-0165~0170 family removed MCP-client coupling, upstream-LLM-provider name dispatch, and the provider color palette from production code and one comment surface. The remaining vendor name occurrences in the dashboard live in the **design canvas** — preview HTML mockups, JSX design canvas scenes, and ui_kits cockpit mock data files. These are not RFC bodies (whose citations stay) nor production fixtures (which mirror external SDK variant constructors); they are 32 mock data files where designers seeded vendor names into UI illustration text (cascade chip labels, status bar mocks, log line examples, fake configuration entries).

`rg -i 'anthropic|kimi|claude|gemini|codex|moonshot|...' dashboard/design-system/{preview,ui_kits,headless-core}/` returned 32 files. None of these files are imported by production code; they are static design illustrations.

## 2. Decision

Apply a consistent vendor-agnostic mapping across the 32 files. The mapping preserves the *multi-provider* design intent (chip color slots, cascade fan-out illustration, status diversity) while removing every specific vendor identity.

| Original | Replacement |
|----------|-------------|
| `anthropic`, `Anthropic` | `provider-a`, `Provider-A` |
| `moonshot`, `Moonshot` | `provider-b`, `Provider-B` |
| `kimi`, `Kimi` (word) | `provider-c`, `Provider-C` |
| `openai`, `OpenAI` | `provider-d`, `Provider-D` |
| `xai`, `xAI`, `ANTHROPIC` (case) | `provider-e`, `Provider-E`, `PROVIDER-A` |
| `gemini`, `Gemini` | `provider-f`, `Provider-F` |
| `deepseek`, `DeepSeek` | `provider-g`, `Provider-G` |
| `qwen`, `Qwen` (word) | `provider-h`, `Provider-H` |
| `groq`, `Groq` | `provider-i`, `Provider-I` |
| `mistral`, `Mistral` (word) | `provider-j`, `Provider-J` |
| `glm`, `GLM` (word) | `provider-k`, `Provider-K` |
| `nemotron`, `Nemotron` | `provider-l`, `Provider-L` |
| `codex_cli` | `cli-tool-a` |
| `gemini_cli` | `cli-tool-b` |
| `kimi_cli` | `cli-tool-c` |
| `claude_code` | `cli-tool-d` |
| `claude-3-5-sonnet-...`, `claude-sonnet-X.Y` | `model-a-sonnet` |
| `claude-haiku-X-Y` | `model-a-haiku` |
| `kimi-k2.6:cloud` etc. | `model-c:cloud` etc. |
| `kimi-for-coding` | `model-c-coding` |
| `gpt-5.3-codex-spark` | `model-d-spark` |
| `gpt-4o`, `gpt-4o-mini`, `gpt-X.Y` | `model-d`, `model-d-mini` |
| `grok-X` | `model-e` |
| `llama-3.1-70b`, `llama3`, `llama-3` | `model-llama-large`, `model-llama`, `model-llama-3` |
| `mistral-large` | `model-mistral` |
| `claude` (standalone) | `agent-llm-a` (post-paste `agent-claude` → `agent-llm-a`) |
| `codex` (standalone) | `agent-code` |

The mapping is **lossy by design**: a future operator reading `provider-a` does not learn which vendor it represented in the original design source. That is the explicit goal — design canvas should not advertise specific vendors.

## 3. Non-changes (intentionally kept)

| Surface | Reason |
|---------|--------|
| `dashboard/design-system/audits/*.md` | Historical design audit; same role as RFC body citation. |
| `dashboard/design-system/RFC/*.md` | Internal design RFC bodies. |
| `dashboard/design-system/CHANGELOG.md`, `README.md`, `SKILL.md` | Historical changelog / readme citation surfaces. |
| `keeper-identity.ts` `'llama'` (animal) | False positive on substring scan. |
| `ollama:` lines in mock data | LLM serving framework, not vendor name. Already kept (matches `nginx:`/`postgres:` pattern). |
| `Ollama` token mentions | Same as above. |
| `nick0cave`, `sangsu` keeper aliases | User's own keeper identities, not vendors. |

## 4. Verification

- `rg -i 'anthropic|\bkimi\b|\bclaude\b|\bgemini\b|\bcodex\b|moonshot|deepseek|\bqwen\b|mistral|\bgroq\b|gpt-|grok|\bxai\b|\bglm\b|nemotron' dashboard/design-system/{preview,ui_kits,headless-core}/` returns 0 hits.
- `pnpm run typecheck` clean (no TS production code touched).
- `dune build lib/ bin/` unchanged (no OCaml touched).

## 5. Workaround-rejection self-check

This RFC rewrites mock data text. It does not add code paths.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO (the new generic names are mock data only; no dispatch on `provider-a`).
3. "PR #N fixed K of M sites" — NO (sweeps the entire 32-file design canvas roster).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 6. Trade-off acknowledgement

Per `software-development.md` and operator memory `feedback-big-bang-refactor-preference`: vendor name removal is preferred over preserving the visual fidelity of design illustrations that advertise a closed roster of LLM vendors. The design canvas retains its illustrative purpose (multi-provider cascade fan-out, status diversity, mock log lines) with generic names; the only thing lost is the specific brand association in the mock.

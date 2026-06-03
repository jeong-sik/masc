# RFC-0169 Dashboard common/* MCP-client attribution header purge

| | |
|---|---|
| Status | Draft |
| Related | RFC-0165 (auth client-agnostic), RFC-0166 (server big-bang sweep), RFC-0167 (agent-code/llama purge), RFC-0168 (provider palette) |
| Scope | `dashboard/src/components/common/*.ts` JSDoc header comments, `dashboard/src/api/dev-token.ts` inline comment |
| Repos | masc |

## 1. Problem

RFC-0165 / 0166 / 0167 cleared client/provider name literals from `lib/` and `bin/`. RFC-0168 cleared the dashboard's closed-roster provider color palette. The remaining MCP-client name surface in `dashboard/src/` is JSDoc-style attribution comments that cite the original design-doc source ("Provider-C design system secXX") and one inline comment in `dev-token.ts` mentioning a competing MCP-client paste flow.

- 33 files under `dashboard/src/components/common/` open with `// Provider-C design system secXX:` or `// Provider-C secXX:` header comments. Two of them further cite `Provider-A Constitutional AI` (`agent-trust.ts`) and `Google AI Human-in-the-loop` (`human-in-the-loop.ts`) as UX pattern sources.
- `dashboard/src/api/dev-token.ts:33` carries an inline comment referencing `"an old agent-code paste/URL token"` as an example of a borrowed non-dashboard token.

None of these surfaces dispatch on the cited names — they are pure attribution / example references. The names persist only as comment-level reminders of the original design-doc source.

## 2. Decision

- Sweep `Provider-C design system sec` → `MASC dashboard sec` and `Provider-C sec` → `MASC sec` across all 33 `common/*.ts` headers.
- Rewrite the two paired LLM-vendor citations to vendor-agnostic phrasing:
  - `Provider-A Constitutional AI-inspired confidence indicator` → `Constitutional-AI-style confidence indicator`
  - `Google AI Human-in-the-loop pattern` → `Human-in-the-loop UX pattern`
- Rewrite the `dev-token.ts:33` example to `old MCP-client paste/URL token` (drop the vendor-specific tool name).

## 3. Non-changes (intentionally kept)

| Surface | Token | Reason |
|---------|-------|--------|
| `keeper-state-diagram.ts:76` | `AGENT-LLM-A.md` | Project instruction file name. Not a vendor. |
| `keeper-identity.ts:15` | `'llama'` | Animal name inside the keeper nickname pool, sibling to `cobra`/`gecko`/`lemur`/`manta`. False positive on the substring scanner. |
| `runtime-config-panel.ts:893` | `case 'ollama': return 'Ollama'` | `ollama` is an LLM serving framework (akin to nginx/postgres), not an MCP-client or upstream-LLM-provider name. Exhaustive closed-sum match — not a string-classifier. |
| `dashboard-runtime.ts:72` | `'cli' \| 'ollama' \| 'other'` | Capability-bucket label union, mirrored on the OCaml backend (`server_routes_http_routes_runtime.ml:16`). Same rationale as above. |
| `dashboard.ts:641,644` / `config-resolution-panel.ts:465` | `Ollama` / `ollama warm` | LLM serving framework references in operator-facing labels. |
| `skeleton.ts:5` | `Lukew / Google Web Vitals` | Web-platform research citation (LCP/FID/CLS metric origin), not an LLM vendor. |
| `components/common/keeper-identity.ts:15` | `llama` (in animal list) | False positive (animal). |

The non-changes preserve operator-facing accuracy where the token is a real product name (Ollama as a serving framework) or non-LLM citation (Web Vitals).

## 4. Verification

- `rg -i 'provider-c|provider-a|\bclaude\b|\bcodex\b' --glob '!*.test.ts' --glob '!*.test.tsx' dashboard/src/` returns only `AGENT-LLM-A.md` reference in `keeper-state-diagram.ts` (project instruction file name, intentionally kept).
- `pnpm run typecheck` clean.
- `dune build lib/ bin/` unchanged (no OCaml touched).

## 5. Workaround-rejection self-check

This RFC rewrites comments and one example string. It does not add code paths.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO.
3. "PR #N fixed K of M sites" — NO (sweeps the entire 33-file common/ attribution roster + the dev-token example in one PR).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 6. Out of scope (later sweeps)

- `dashboard/src/**/*.test.ts` and `*.test.tsx` fixture strings (~49 files; mostly cosmetic asserts).
- `test/` OCaml fixture strings (~210 files).
- `dashboard/design-system/{audits,preview,SPEC.md}` historical references (~48 files).
- `docs/` history references (~234 files).

These are pure documentation / test-fixture sweeps with no code-path implications and are deferred to a later mass-sed pass.

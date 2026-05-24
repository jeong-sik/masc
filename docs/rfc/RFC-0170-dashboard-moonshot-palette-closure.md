# RFC-0170 Dashboard provider-b palette closure (RFC-0168 N-of-M follow-up)

| | |
|---|---|
| Status | Draft |
| Supersedes-in-part | RFC-0168 §6 (deferred SPEC.md + preview sync) |
| Related | RFC-0165 / 0166 / 0167 / 0168 / 0169 (client-agnostic family) |
| Scope | `dashboard/design-system/tokens.generated.css`, `dashboard/design-system/ui_kits/cockpit/tokens.generated.css`, `dashboard/design-system/SPEC.md`, `dashboard/design-system/preview/colors.html`, `dashboard/design-system/preview/index.html` |
| Repos | masc-mcp |

## 1. Problem

RFC-0168 (PR #18219) removed 14 closed-roster `--p-<vendor>` color tokens (`provider-a`, `provider-c`, `provider-d`, `provider-e`, `provider-f`, `provider-g`, `provider-h`, `provider-j`, `provider-l`, `ollama`, `llamacpp`, `provider-k`, `provider-f-cli`, `agent-code-cli`) from `dashboard/design-system/tokens/source.ts` and the live generated CSS surfaces.

**RFC-0168 inventory was 14-of-15**: `--p-provider-b` / `--p-provider-b-soft` / `--p-provider-b-border` was carried in both `dashboard/design-system/tokens.generated.css` and `dashboard/design-system/ui_kits/cockpit/tokens.generated.css` but missed by the source.ts sweep. This is the workaround-rejection §3 (N-of-M patch) signature.

`SPEC.md §3.6.5 "Provider cascade (unchanged)"` and `preview/colors.html §"Provider Palette (W15)"` still document the removed tokens as live surfaces.

`rg -l 'p-provider-b' dashboard/src/` returned **zero production consumers** — the token has been dead since RFC-0168 merged.

## 2. Decision

- Delete `--color-p-provider-b` (line 55), `--color-p-provider-b-soft` / `--color-p-provider-b-border` (lines 262-263) from `dashboard/design-system/tokens.generated.css`.
- Delete `--p-provider-b` (line 56), `--p-provider-b-soft` / `--p-provider-b-border` (lines 263-264) from `dashboard/design-system/ui_kits/cockpit/tokens.generated.css`.
- Rewrite `SPEC.md §3.6.5` from `"Provider cascade (unchanged)"` to `"Provider cascade (removed by RFC-0168 / RFC-0170)"` with a one-paragraph rationale.
- Replace `preview/colors.html §"Provider Palette (W15)"` (44 lines of dead chip markup) with a comment marker pointing at the two RFCs.
- Rewrite the `preview/index.html` link card description from `LLM provider tints — desaturated, muted. ... <code>--p-provider-a</code> etc.` to `Closed-roster vendor palette removed by RFC-0168 / RFC-0170. Cascade chips render with neutral styling.`

## 3. Out of scope (intentional)

| Surface | Reason |
|---------|--------|
| `dashboard/design-system/audits/*.md` | Historical design audit reports; same role as RFC body citation — preserved for design history. |
| `dashboard/design-system/preview/cb-*.jsx`, `preview/*.html` mock data | Design canvas snapshot; vendor names inside mock UI text are part of the original design illustration (cascade chip examples, status bar mocks, etc.). Rewriting to generic strings would erase design history without removing any token / code path. |
| `dashboard/design-system/RFC/00{21,23}*.md` | Internal design RFC bodies; same as above. |
| `dashboard/src/**/*.test.ts`, `test/` OCaml fixtures | These mirror backend wire format (`model_id: 'model-c:cloud'`, `actor: 'agent-llm-a'`, `Llm_provider.Provider_config.Kimi_cli` etc.). The vendor names are *protocol-level model IDs* from external SDKs and *closed-sum variant constructors* defined in the `agent_sdk.llm_provider` opam package — neither is within masc-mcp's scope to rename. |
| `docs/` history references | RFC body and audit citations; same as audits/. |

## 4. Verification

- `rg -i 'p-provider-b|p-provider-a|p-provider-c|p-provider-d|p-provider-e|p-provider-f|p-agent-code' dashboard/design-system/tokens*.css dashboard/design-system/ui_kits/cockpit/tokens.generated.css` returns 0 hits (token defs).
- `rg -l 'p-provider-b' dashboard/src/` returns 0 (no production consumer).
- `pnpm run typecheck` unchanged (no TS touched).
- `dune build lib/ bin/` unchanged (no OCaml touched).

## 5. Workaround-rejection self-check

This RFC removes one dead-token triple and syncs three documentation surfaces. It does not add code paths.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO.
3. "PR #N fixed K of M sites" — **THIS IS THE FIX** (closes the RFC-0168 N-of-M residue).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO (signature 3 is the *closure*, not introduction).

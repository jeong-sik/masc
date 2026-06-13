# RFC-0168 Dashboard upstream-LLM-provider color palette purge

| | |
|---|---|
| Status | Draft |
| Related | RFC-0166 (server big-bang sweep rev2), RFC-0167 (agent-code omission-dedup + Llama discovery) |
| Scope | `dashboard/design-system/tokens/source.ts`, all generated token outputs, `dashboard/src/styles/tokens.css`, `dashboard/src/components/ide/overlay-runtime.solid.test.tsx` |
| Repos | masc |

## 1. Problem

After RFC-0165 / 0166 / 0167 cleared all upstream-LLM-provider and MCP-client name literals from `lib/` and `bin/`, the dashboard frontend still carried a closed roster of provider colors:

- `dashboard/design-system/tokens/source.ts:155-169` — 14 raw color tokens (`p-provider-a`, `p-provider-c`, `p-provider-d`, `p-provider-e`, `p-provider-f`, `p-deepseek`, `p-provider-h`, `p-provider-j`, `p-provider-l`, `p-ollama`, `p-llamacpp`, `p-provider-k`, `p-provider-f-cli`, `p-agent-code-cli`).
- `dashboard/design-system/tokens/source.ts:499-517` — 14 paired soft/border semantic variants generated from the raw palette.
- All generated outputs (`dashboard/src/styles/tokens.generated.{ts,css}`, `dashboard/design-system/source_styles/tokens.generated.css`, `dashboard_bonsai/src/tokens.{ml,mli}`, `dashboard_bonsai/static/colors_and_type.generated.css`, `dashboard/design-system/tokens/build/tokens.json`).
- Stale generated artifacts not produced by `pnpm tokens:build` but committed: `dashboard/design-system/tokens.generated.css`, `dashboard/design-system/ui_kits/cockpit/tokens.generated.css`.
- `dashboard/src/styles/tokens.css:116-160` — handwritten counterpart of the same palette.
- `dashboard/src/components/ide/overlay-runtime.solid.test.tsx:91-92,141,149` — test fixture locked the assertion to specific upstream-provider names (`provider-a`, `model-a-sonnet`, `--color-p-provider-a`).

`rg` showed **zero production consumers** of these tokens — the palette was referenced only within its own definition files and one negation-assertion test. The closed roster of upstream provider names was dead weight.

## 2. Decision

- Remove both palette sections from `dashboard/design-system/tokens/source.ts` and regenerate all live outputs via `pnpm tokens:build`.
- Sed-purge the same token names from the stale generated artifacts and from `dashboard/src/styles/tokens.css`.
- Rewrite the `overlay-runtime.solid.test.tsx` SAMPLE_HIT fixture to use neutral `sample-provider-alpha` / `sample-model-beta` strings; restate the negation assertions in terms of the new fixture or the generic `--color-p-` prefix.
- Preview/audit HTML files under `dashboard/design-system/preview/` and the RFC-style audit reports under `dashboard/design-system/audits/` retain historical references — they are out of scope (handled by a later docs sweep).

## 3. Behavior consequences (operator-acknowledged)

| Path | Before | After |
|------|--------|-------|
| Runtime chip styling | Could lookup `var(--p-provider-a)` etc. (dead path; not actually used) | Token doesn't exist; chips render with neutral border-default styling, which is what they already did in production |
| Runtime preview HTML (`dashboard/design-system/preview/colors.html`) | Visualized 14-color provider palette | Will eventually need a re-snap; out of scope here |
| Stale generated css files | Carried 14 provider colors | Sed-stripped |

No live UX regression — the palette was dead code.

## 4. Verification

- `pnpm tokens:build` clean.
- `rg 'p-(provider-a|provider-c|provider-d|provider-e|provider-f|deepseek|provider-h|provider-j|provider-l|ollama|llamacpp|provider-k|agent-code)' dashboard/src/` returns 0 hits.
- `dune build lib/ bin/` clean (OCaml core unaffected).
- `pnpm vitest run` — 5 tests fail. 4 of those failures are origin/main baseline (verified by running the same subset against `origin/main` via stash); the remaining 1 is unattributed in this PR.

## 5. Workaround-rejection self-check

This RFC removes; it does not add.

1. "makes X visible" without fixing — NO.
2. String/substring/prefix classifier added — NO (`overlay-runtime` test's negation assertion uses `--color-p-` prefix only to ensure no provider-tinted token leaks; it does not enumerate names).
3. "PR #N fixed K of M sites" — NO (sweeps the entire roster in one PR).
4. catch-all `_ ->` added — NO.
5. cap / cooldown / dedup / repair — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 6. Out of scope (later docs sweep)

- `dashboard/design-system/SPEC.md`, `dashboard/design-system/audits/2026-04-28-production-css-drift.md`, `dashboard/design-system/preview/{index,colors}.html` — historical / preview surfaces with embedded provider-name references.
- `dashboard/src/**/*.test.ts` fixture strings unrelated to the palette (36 files total; most are cosmetic asserts that don't dispatch on provider name).
- `dashboard/src/components/common/*.ts` JSDoc-style header comments citing "Provider-C design system sec05" or similar code-attribution references.

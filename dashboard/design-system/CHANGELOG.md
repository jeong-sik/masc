# MASC Cockpit Design System — Changelog

All notable changes to the canonical design system live here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with project-specific phase markers.

---

## [Unreleased] — v0.4 (in progress)

Stage: legacy alias cleanup + KeeperBadge migration completion + token codification sweep + **SSOT codegen migration** (3-stack token unification, drift-prevention CI, 14-atom + W## roadmap support).

### Added — SSOT codegen migration (2026-04)

- **Codegen scaffold** — PR #11189
  - `dashboard/design-system/tokens/source.ts` (typed authoring SSOT, raw + semantic + role + 2 themes)
  - `dashboard/design-system/tokens/build.ts` (~265L codegen driver, `culori` for OkLCH 12-slot keeper palette)
  - 4 generated outputs side-by-side with originals (suffix `.generated.*`)
  - `dashboard/design-system/tokens/build/tokens.json` (DTCG 2025.10, committed)

- **Bonsai colors_and_type CSS output (artifact 7/7)** — PR #11235
  - `build.ts` extended to emit `dashboard_bonsai/static/colors_and_type.generated.css` (Bonsai naming: `--bg-deep` / `--accent-brass` / `--space-*` / `--status-*`)
  - 2 themes only (per user decision): dark-fantasy canonical on `:root`, paper light on `[data-theme="paper"]`
  - cyberpunk / terminal / parchment archived to `dashboard_bonsai/static/themes/archive/`

- **source.ts superset extension** — PR #11275
  - +32 tokens (raw 11, role 21) covering Preact components 40+ that referenced legacy hand-written tokens
  - 51 dead tokens explicitly skipped (Unknown→Permissive Default anti-pattern avoided)
  - Includes per-keeper `--color-keeper-N-glow` (1..12), `--color-text-{strong,body,muted,dim}`, font-size scale, tracking, paper theme `*-fill` variants

- **`tokens-drift` CI workflow** — PR #11293
  - 4 gates active on main as required PR checks:
    1. **Idempotent build** — `pnpm tokens:build` followed by `git diff --exit-code` (source.ts ↔ generated sync structural enforcement)
    2. **Status canon pin** — `--ok/--warn/--err/--info` hex values frozen at `#6b9e6b/#c9a24a/#c46a5a/#6a8eb0` (warm dim per SPEC §3.5)
    3. **Keeper OkLCH ΔE < 2** — algorithmic check vs `OkLCH(L=0.68, C=0.09, H=(i-1)*30)`, catches `culori` regressions
    4. **Tier integrity** — generated files cannot be modified without corresponding source.ts change (no hand-edit of generated)

- **`check-equivalence.mjs` restoration** — PR #11330
  - Restored after PR #11250 collateral deletion. Simplified to single-axis (status canon + keeper ΔE), removed legacy hand-written reference. Idempotent build subsumes name-set superset.

- **SPEC.md §12 audit section + outdated sweep** — PR #11433
  - SPEC §1 stylesheet system table updated (2 active themes, 3 archived locations)
  - SPEC §6 process replaced ("source.ts SSOT → `pnpm tokens:build` → 7 generated artifacts → CI idempotency")
  - SPEC §10-11 historical PR-S/M tables consolidated into §12 audit
  - README.md tier definitions + directory tree refreshed

### Removed — Hand-written CSS purge across all surfaces

- **Preview surface** — PR #11250
  - `dashboard/design-system/source_styles/tokens.css` (880L)
  - `dashboard/design-system/source_styles/semantic.css` (117L)
  - `dashboard/design-system/colors_and_type.css` (20L façade)
  - preview/index.html `<link>` repointed to `tokens.generated.css`

- **Preact surface** — PR #11255
  - `dashboard/src/styles/tokens.css` (137L)
  - Tailwind v4 `@theme` directive verified in entry CSS (issue #18966 mitigation)
  - paper theme already URL-param + localStorage controlled (no hardcoded changes needed)

- **Bonsai surface** — PR #11301
  - `dashboard_bonsai/static/colors_and_type.css` (566L hand-written)
  - HTML `<link>` repointed via `lib/server/server_routes_http_pages.ml:319` + `mk/build.mk` copy target updated
  - 3 themes (cyberpunk / terminal / parchment) archived to `dashboard_bonsai/static/themes/archive/` (brand voice preserved, not deleted)

### Migration impact (codegen migration sub-stage)

- **~1720L hand-written CSS deleted** across 3 surfaces; replaced by 7 codegen artifacts emitted from a single TypeScript SSOT.
- **0 cross-surface drift possible** — `tokens-drift` workflow rejects any PR that diverges generated from source.ts.
- **3-stack vocabulary unified** at the SSOT level while preserving per-stack naming conventions (Preact `--bg-0` / Bonsai `--bg-deep` / preview shared) via codegen translation rules.

### Added — earlier v0.4 work

- **4-slot fg tier — partial codification** (raw tier, forward alias / visual byte-identical) — PR #11131
  - `--rose-fg: #fecdd3` — covers `text-[#fecdd3]` 5 callsites paired with `--rose-{10,28}`
  - `--emerald-fg: #bbf7d0` — covers `text-[#bbf7d0]` 3 callsites paired with `--emerald-{10,12,8,30}`
  - Codification rule: ≥3 callsites + paired context (same family) + no Semantic naming conflict.
  - Pending: `--purple-fg`/`--violet-fg` (naming consolidation needed), `--accent-fg` (collides with Semantic `--color-accent-fg`), `--sky-fg` family.

- **Family scale gap fills** (raw tier, forward alias / visual byte-identical) — PR #11131
  - `--bad-50: rgba(239, 68, 68, 0.50)` — fills missing 0.50 step in `--bad-{6,10,15(soft),20}` family. 6 callsites swept (fsm-hub-timeline-panels prod + test).
  - `--accent-6: rgba(71, 184, 255, 0.06)` — fills missing 0.06 step in `--accent-{8,10,12,15-soft,16,18,20,30,36}` family. 3 callsites swept (chat/primitives, keeper-detail, fsm-hub-pipeline-panels).

- **Bonsai trace-frame migration** — `dashboard_bonsai/src/shell_view.ml` `.flame_{plan,exec,wait,err}` raw hex → `--t-{think,tool,wait,err}` Semantic (closes v0.3 "bonsai-side PR pending" item). `.flame_block` 2 hex retained as SPEC §2 escape hatch.

- **Audit follow-up doc** — `dashboard/design-system/audits/spec-compliance-2026-04-27-followup.md` documents Stage 1 progress, codification criteria, and remaining design-decision territory.

### Removed

- **Legacy keeper aliases purged** — completing the v0.3 deprecation cycle one minor early (no remaining callers in dashboard preview).
  - `tokens.css`: `--k-nick / -masc / -sangsu / -qa / -rama` (+ `-glow`, `-soft`, `-border`, `-ring`) — 25 tokens removed.
  - `tokens.css`: `.dot-k-nick / -masc / -sangsu / -qa / -rama` CSS rules (5 selectors).
  - `cb-shared.jsx`: `kClass()` function and its `window.*` export.
  - `cb-stress-10keepers.html` (the v1 "before" demo) — superseded by `-v2`. v2 is now the only stress-test page.
- **18 component callsites migrated** from `<Dot kind={kClass(id)}>` → `<KeeperBadge id={id} variant="sigil"|"full">` across cb-group-a/b/c/d/h. Two patterns:
  - `variant="sigil"` where the keeper name is rendered separately (ticker, lifeline, sidebar, swimlanes, BDI panel, kanban, rail).
  - `variant="full"` where the badge owns both color+sigil+name (table cells, kanban foot).
- **`primitives.html`**: dead `class="dot-k-nick"` + duplicate `class=` attribute on heartbeat anim demo cleaned.

### Migration impact

- 0 callers in `dashboard/` reference removed names.
- Cross-project references (bonsai etc.) — if any — must migrate to `--k-N` / `--color-keeper-N` / `<KeeperBadge>`.

---

## [v0.3] — Keeper attribution overhaul

### Added

- **v0.3 — Keeper attribution overhaul** (palette + sigil channel)
  - **12-slot OkLCH spectrum** (`tokens.css` §3): `--k-1` … `--k-12` at L=68%, C=0.09, hue stride 30°. Adjacent ΔE ≥ 25, all ≥4.5:1 contrast on `--bg-0`. Each slot exposes `-soft`, `-border`, `-ring`, `-glow` (4-slot semantics) → 60 new tokens.
  - **Canonical façade**: `--color-keeper-1` … `--color-keeper-12` exposed at SPEC §3.6 tier.
  - **`<KeeperBadge>` + `<KeeperStack>` + `kSlot()` + `kSigil()`** in `cb-shared.jsx` — canonical attribution primitives. FNV-1a hash → 12-slot mapping; 5 anchor IDs pinned in `KEEPER_REGISTRY`.
  - **SPEC §3.6 v0.3 revised**: color-only attribution forbidden; 2-letter sigil mandatory as second channel; `<KeeperStack cap={4}>` with `+N` overflow when keepers > 4.
  - **`cb-stress-10keepers-v2.html`**: re-runs the 10-active worst case against the new palette + sigil channel — all 5 patterns flip from FAIL → PASS verdict.

- **`cb-group-g` — state patterns** (10 variants across 5 groups)
  - **Empty states**: Vacant zone (lifeline-style with ASCII art), "no results" (filter context with reset CTA).
  - **Loading skeletons**: Row shimmer (3-line ticker), KPI cell shimmer, panel shimmer (header + body).
  - **Error surfaces**: Recoverable warn (with retry CTA), fatal error (with diagnostic frame ID).
  - **Pagination**: Cursor-style (← prev / → next + page count), numbered (with ellipsis for ranges).
  - **Breadcrumb**: Standard (separator chevron), bilingual KR/EN with last-segment `aria-current="page"`.
  - All variants follow SPEC §5 a11y catalog: `role="status"` / `aria-live="polite"` for transient surfaces, `role="alert"` for fatal errors, `<nav>` + `aria-label` for pagination/breadcrumb, decorative glyphs marked `aria-hidden="true"`.
  - Files: `preview/cb-group-g.jsx`, `preview/cb-group-g.html` — live showcase wired into `preview/index.html` under "Common patterns".

- **Motion tokens** (`source_styles/tokens.css` §6 — already present in SSOT, now formally exposed)
  - Curves: `--ease`, `--ease-out`, `--ease-in`, `--ease-inout`, `--ease-spring` (5)
  - Durations: `--t-fast`, `--t-med`, `--t-slow`, `--t-xslow` (4)
  - Role tokens: `--motion-enter`, `--motion-exit`, `--motion-swap`, `--motion-reveal`, `--motion-settle`, `--motion-pop` (6)
  - `prefers-reduced-motion: reduce` block flattens all durations to `1ms` and removes spring overshoot.

- **Trace-frame tokens** (`source_styles/tokens.css` §7) — `--t-llm`, `--t-tool`, `--t-think`, `--t-wait`, `--t-err`. Defined for default + 5 themes (dark-fantasy / cyberpunk / terminal / parchment / paper). Replaces the raw `.flame_*` hex values in `dashboard_bonsai/shell_view.ml` (bonsai-side migration completed in PR #11131).

- **5-theme matrix** consolidated to single SSOT (`source_styles/tokens.css`).
  - Themes: `dark-fantasy` (default), `cyberpunk`, `terminal`, `parchment`, `paper`.
  - Each theme overrides raw bg / fg / border / accent / radius / shadow / font as needed; semantic and role aliases are theme-agnostic.

### Changed

- **Default theme is now strictly dark.** Removed the `@media (prefers-color-scheme: light)` auto-flip block in `tokens.css`. The dark-fantasy stack is the canonical default; light surfaces require an explicit `data-theme="paper"` (or `"light"`) on `<html>`. Honors original SPEC intent — `prefers-color-scheme` was leaking OS preference into the design and overriding the brand palette on light-mode laptops.

- **`colors_and_type.css` is now a thin façade** over `source_styles/tokens.css` to eliminate cascade drift between the historical 159-line file and the 921-line SSOT.
  - All `--color-*` semantic aliases now resolve through `tokens.css`.
  - Legacy short-form aliases (`--color-bg`, `--color-text`, `--color-border`) preserved for back-compat but marked `@deprecated` in comments — to be removed in v0.3.
  - Migration path documented in SPEC §7.1.4.

- **`preview/index.html` link order**
  - Now imports `tokens.css` first, then `type_layer.css`, then `primitives.css`.
  - `colors_and_type.css` deliberately not re-imported to avoid double-cascade. SPEC §7.1.4.

### Reference rewiring

- "Common patterns" group on `preview/index.html` gained the `cb-group-g · State patterns` card.
- "Reference" group now points to **SPEC.md** and **CHANGELOG.md** (this file) instead of an outdated README pointer.

### Verified

- cb-group-g rendered in preview, 11 a11y landmarks present, 0 console errors (verifier agent pass, 2026-04).

---

## [v0.1] — Phase 1+2+3 component coverage

Stage: cockpit zones complete.

### Added

- **Phase 1 — Cockpit zones** (cb-group-a..f, 11 components × 31 variants)
  - Topbar, ticker, KPI, lifeline, sidebar, swimlanes, deck, rail, composer, status bar, drawer.

- **Phase 2 — Work / Comms / Observability / Cognition planes** (cb-group-h..k)
  - **I0** IDE backbone (3 variants): branch selector, keeper multi-select, operator nudge log.
  - **G1-G3** Work: Goal Zone, Task Zone, Accountability (8 variants).
  - **C1-C3** Comms: Board Zone, Messages, Composer v2 (9 variants).
  - **O1-O5** Observability: Cascade, Audit, Safe Autonomy, Cost & Latency, Heuristic + Stress (15 variants).
  - **K1-K4** Cognition: Keeper Inspector v2, Decisions / Memory, Institution Episodes, Autoresearch (10 variants).

- **Phase 3 — Code IDE plane** (`code-mode.jsx`, E1..E5, 20 variants)
  - File Tree, Editor Surfaces, PR Inspector, Branch Graph, Terminal / Search.

- **Foundations**
  - 3-tier token taxonomy (Raw → Semantic → Role) — SPEC §2.
  - Surface stack, type system (11 roles), spacing (4px base), 7-step elevation, brand vocabulary.
  - Preview pages: `colors`, `type`, `spacing`, `brand`, `primitives`, `forms`, `overlays`, `snippets`.

- **Showcase**
  - `ui_kits/cockpit/` — single-page wired prototype (App + Chrome + Panels + Planes + cockpit.css).

---

## Versioning policy

- **Patch** (v0.x.y): bugfix, doc clarification, no token or component-shape change.
- **Minor** (v0.x): new tokens, new components, additive a11y enhancements. Existing token names preserved.
- **Major** (vx.0): breaking — token renames, removal of deprecated aliases, theme matrix changes that require call-site updates.

Per SPEC §1: **the spec changes before the code does.** Any new token / component pattern / theme starts with a SPEC PR; this changelog documents the implementation that follows.

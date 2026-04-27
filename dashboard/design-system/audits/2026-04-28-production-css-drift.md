# Phase 0 Audit — Production CSS ↔ Design-System Token Drift

- **Generated**: 2026-04-27T16:15Z (KST 2026-04-28 01:15)
- **Branch**: `feature/ds-drift-phase0-audit`
- **Base commit**: `86053a88bb`
- **Scope**: 19 hand-written CSS files under `dashboard/src/styles/` (excluding `tokens.generated.css`/`tokens.generated.ts`)
- **Plan**: `~/me/planning/claude-plans/20m-me-workspace-yousleepwhen-masc-mcp-h-curious-dusk.md`
- **Method**: comments stripped (`/\*…\*/`), then `rg` counts. Hex catalog lower-cased, deduped per file.

---

## 1. Summary <a id="summary"></a>

| Metric | Value |
|---|---|
| Production CSS files audited | 19 |
| Total source lines | 2 138 (excluding `tokens.generated.css` 376 LOC) |
| `var(--*)` usages (token references) | 297 |
| Hard-coded hex colour occurrences | 96 (90 unique) |
| Token usage ratio (color/text axis) | **75.6 %** (`297 / (297 + 96)`) |
| Hard-coded `*px` occurrences | 271 |
| Hard-coded `*rem` occurrences | 9 |
| Files actually imported in `main.ts` | 13 |
| **Orphan files (zero `import` reference)** | **6** — `chat.css`, `pipeline.css`, `live-monitor.css`, `keeper-detail.css`, `pixel-avatar.css`, `responsive.css`, `a11y.css` (only commented references) |

The drift is **not uniform**. Two files account for >70 % of all hard-coded hexes: `paper-theme.css` (32 hexes, intentional theme override) and `variables.css` (40 hexes, legacy semantic table). The remaining 17 files contain only 24 hexes combined. The **bigger drift is in dead code shipped as source**: 7 files appear in tree but are not loaded by any production entrypoint, while `CSS-ARCHITECTURE.md` still documents them as "Component-Specific Files".

---

## 2. Per-file audit table <a id="per-file-audit-table"></a>

`var()` and `hex` columns count **occurrences** (not unique). `selectors` is an approximation: line-anchored `{` count, comments stripped. `imports` is the production trace via `rg` against `dashboard/src/**/*.{ts,tsx,jsx,html}` — the 3 most relevant files only; `(orphan)` means **no production entrypoint** loads it.

| File | Lines | Selectors* | `var(--*)` | Hex | px | rem | Production import | Domain |
|---|---:|---:|---:|---:|---:|---:|---|---|
| `governance.css` | 41 | 4 | 3 | 0 | 4 | 0 | `src/main.ts:28` | governance |
| `governance-agent.css` | 20 | 2 | 2 | 0 | 3 | 0 | `src/main.ts:29` | governance |
| `paper-theme.css` | 155 | 3 | 50 | **32** | 0 | 0 | `src/main.ts:18`, `components/theme-switch.ts` | theme |
| `ops.css` | 15 | ~0 | 3 | 2 | 0 | 0 | `src/main.ts:30` | component |
| `board.css` | 59 | 7 | 3 | 3 | 2 | 3 | `src/main.ts:25` | component |
| `pipeline.css` | 97 | 15 | 3 | 0 | 3 | 0 | **(orphan)** | component |
| `live-monitor.css` | 55 | 1 | 13 | 1 | 2 | 0 | **(orphan)** | component |
| `keeper-detail.css` | 16 | ~0 | 1 | 0 | 1 | 0 | **(orphan)** | component |
| `chat.css` | 85 | 11 | 4 | 7 | 2 | 0 | **(orphan, comment in `main.ts:26`)** | component |
| `pixel-avatar.css` | 112 | 10 | 12 | 0 | 18 | 0 | **(orphan)** | component |
| `keyframes.css` | 176 | 1 (28 `@keyframes`) | 9 | 0 | 18 | 0 | `src/main.ts:13`, `components/motion.ts` | motion |
| `responsive.css` | 81 | 12 | 0 | 0 | 20 | 0 | **(orphan)** | layout |
| `tools.css` | 63 | 4 | 3 | 0 | 12 | 0 | `src/main.ts:31` | component |
| `dashboard.css` | 252 | 33 | 23 | 3 | 31 | 3 | `src/main.ts:27` | layout |
| `ui.css` | 180 | 12 | 43 | 0 | 44 | 0 | `src/main.ts:24`, `components/common/markdown-renderer.ts` | component |
| `base.css` | 42 | 6 | 3 | 3 | 0 | 0 | `src/main.ts:12` | utility |
| `global.css` | 191 | 5 (15 `@utility`) | 50 | 3 | 38 | 0 | `src/main.ts:21` | utility |
| `variables.css` | 399 | 1 (`:root`) | 63 | **40** | 24 | 0 | `src/main.ts:11`, `components/elev.ts`, `components/btn.ts` | utility |
| `a11y.css` | 99 | 7 | 9 | 2 | 21 | 0 | **(orphan, comments in `motion.ts`/`focusable.ts`)** | a11y |

\* Selector count is an approximation — `@keyframes` (28 in `keyframes.css`) and `@utility` blocks (15 in `global.css`) are bracketed differently. A linter pass would be more accurate; this audit uses raw `{` line anchors so absolute numbers are not authoritative, only relative.

### Findings derived from the table

1. **75.6 %** of colour/text references are already token-routed. The drift hypothesis "preview is far from production" is **false at the token-usage axis**; the drift is in *vocabulary coverage* (production owns domain words preview never visualises) not in raw-hex anarchy.
2. **`paper-theme.css`** is the single largest legitimate hex source (32 hexes, all theme-override values). Its hexes are intentional: they redefine `--bg-0…4`, `--fg-1…4`, `--accent-*`, `--ok/warn/err/info`, `--p-anthropic/moonshot/openai/xai` for the *paper* theme. Phase 2 should keep them as raw-tier overrides under `[data-theme="paper"]`, but **lift the palette into `tokens/source.ts` `paperOverrides`** so the codegen owns it.
3. **`variables.css`** carries 40 hexes inside a single `:root` block. It is a **legacy semantic catalog** (slate scale, purple scale, brick scale, brass scale, status alphas). Phase 2 should migrate this entire file into `tokens/source.ts` and delete it; this is the highest-ROI single-file rewrite.
4. Seven files (`chat`, `pipeline`, `live-monitor`, `keeper-detail`, `pixel-avatar`, `responsive`, `a11y`) ship in tree but are not imported. Either they were inlined into `global.css` `@utility` blocks (the `chat.css` comment in `main.ts:26` confirms this for one of them), or they are dead. **Phase 1 must verify per file** before treating them as production source.
5. Of the 96 hex occurrences, **72 are concentrated in 2 files** (paper-theme + variables). The "hardcoded value problem" outside those two files is small (24 occurrences across 17 files, average <2/file).

---

## 3. Hard-coded value catalog <a id="hardcoded-value-catalog"></a>

### 3.1 Hex frequency Top-30 (across 19 files, comments stripped)

| Hex | Count | Appears in | Closest existing token (from `tokens/source.ts`) | Recommendation |
|---|---:|---|---|---|
| `#ff4500` | 2 | `board.css`, `dashboard.css` | (none — saturated orange-red) | **new token candidate** `--brand-reddit` (or rename: vote-up) |
| `#e2e8f0` | 2 | `variables.css`, `a11y.css` | (none — Tailwind slate-200) | **new token** `--slate-200` (light theme placeholder) |
| `#ccc` | 2 | `board.css`, `dashboard.css` | `--fg-3` (`#7a7065`) loose match | replace with `--color-fg-muted` |
| `#b8c0cc` | 2 | `global.css` (×2) | (none — neutral grey-blue) | **new token** `--neutral-300` |
| `#7193ff` | 2 | `board.css`, `dashboard.css` | `--p-moonshot` (`#8a98c9`) loose | replace with semantic `--link` token (new) |
| `#0c1424` | 2 | `base.css`, `variables.css` | `--bg-0` (`#0c0b08`) very close | **alias to `--bg-0`** or new `--bg-0-cool` |
| `#ffffff` | 1 | `variables.css` | n/a (pure white) | OK as raw — used for opacity recipes |
| `#0a0f1a` | 1 | `a11y.css` | `--bg-0` close | alias `--bg-0` |
| `#080e1a` | 1 | `base.css` | `--bg-0` close | alias `--bg-0` |
| `#07111f` | 1 | `base.css` | `--bg-0` close | alias `--bg-0` |
| `#a855f7` | 1 | `live-monitor.css` | `--stalled` (`#8a6aa0`) loose | new `--accent-violet` candidate |
| `#fecaca`, `#cffafe` | 1 ea | `ops.css` | (none — Tailwind red-200/cyan-100 light theme tints) | new `--ops-warn-soft`, `--ops-info-soft` |
| `#7a8494` | 1 | `global.css` | `--fg-3` close | replace with `--color-fg-muted` |
| **`paper-theme.css` palette (32 hexes)** | 1 ea | `paper-theme.css` | (data-theme override) | leave raw under `[data-theme="paper"]`; lift definitions into `tokens/source.ts paperOverrides` block |
| **`variables.css` palette (40 hexes)** | 1 ea | `variables.css` | various scales | migrate entire file into `tokens/source.ts` semantic + raw tiers |
| **`chat.css` rose/violet/cyan tints** | 1 ea | `chat.css` | (none) | new `--chat-bubble-self`, `--chat-bubble-peer` semantics — but first verify file is reachable |

Full per-file hex listings (cleaned): see `/tmp/css-stripped/` (build artefact) or run `bash` audit script archived in commit message.

### 3.2 px usage hot-spots

| File | px count | Note |
|---|---:|---|
| `ui.css` | 44 | atomic component sizing — likely intentional |
| `global.css` | 38 | mostly `@utility` block padding/sizing |
| `dashboard.css` | 31 | layout |
| `variables.css` | 24 | spacing/radius constants — should move to tokens |
| `a11y.css` | 21 | focus ring widths, skip-link offsets |
| `responsive.css` | 20 | breakpoint internals (orphan; verify) |

Phase 2 candidate: extract spacing/radius scale used in `variables.css` (24 px values) into `tokens/source.ts spacingScale`/`radiusScale`. Other px usage is mostly atomic and can stay literal until a sizing token RFC lands.

---

## 4. Workstream mapping (W01–W18) <a id="workstream-mapping"></a>

Plan §Phase 1 split, with audited file size and risk.

| # | Workstream | Files (LOC) | New preview page | Hex to extract | Risk |
|---|---|---|---|---:|---|
| W01 | governance tone | `governance.css` (41) + `governance-agent.css` (20) = 61 | `preview/governance.html` (new) | 0 | low |
| W02 | paper-theme | `paper-theme.css` (155) | `preview/themes.html` (new, 5-theme matrix start) | 32 | medium — keep raw, lift into tokens |
| W03 | ops console | `ops.css` (15) | `preview/ops.html` (new) | 2 | low |
| W04 | board feed | `board.css` (59) | `cb-group-c.jsx` update | 3 | low |
| W05 | pipeline | `pipeline.css` (97) **orphan** | `preview/pipeline.html` (new) | 0 | **gate**: confirm file is live before adding preview |
| W06 | live-monitor | `live-monitor.css` (55) **orphan** | `preview/live-monitor.html` (new) | 1 | gate (orphan) |
| W07 | keeper-detail | `keeper-detail.css` (16) **orphan** | `cb-group-h.jsx` update | 0 | gate (orphan, near-empty) |
| W08 | chat | `chat.css` (85) **orphan; merged into global.css** | `cb-group-b.jsx` update | 7 | gate — `main.ts:26` says merged. Decide: delete file OR re-import |
| W09 | pixel-avatar | `pixel-avatar.css` (112) **orphan** | `preview/avatar.html` (new) | 0 | gate (orphan) |
| W10 | keyframes/motion | `keyframes.css` (176) | `preview/motion.html` (new, motion token visualisation) | 0 | low |
| W11 | tools | `tools.css` (63) | `preview/tools.html` (new) | 0 | low |
| W12 | ui core | `ui.css` (180) + `base.css` (42) = 222 | `primitives.html` update | 3 | medium — `base.css` carries 3 dark-blue background hexes |
| W13 | dashboard layout | `dashboard.css` (252) + `responsive.css` (81 **orphan**) = 333 | `preview/layout.html` (new) | 3 | gate (responsive orphan) |
| W14 | a11y | `a11y.css` (99) **orphan** | `preview/a11y.html` (new — focus ring, skip link, aria viz) | 2 | gate (orphan but referenced by JS comments) |
| W15 | provider palette | `tokens/source.ts` providers | `colors.html` provider section (update) | n/a | Phase 1 read-only on `source.ts`; defer write to W17/W18 |
| W16 | z-index stack | `tokens/source.ts` z-index | `preview/layers.html` boost | n/a | Phase 1 read-only |
| W17 (opt) | density matrix | spacing tokens | `spacing.html` density demo | n/a | Phase 2 |
| W18 (opt) | 5-theme matrix | `tokens/source.ts` theme branch | `themes.html` matrix complete | n/a | Phase 2 |

**Workstream classification**:
- **New preview pages** (12): W01, W02, W03, W05, W06, W09, W10, W11, W13, W14, W17, W18.
- **Updates to existing preview** (6): W04 (cb-group-c), W07 (cb-group-h), W08 (cb-group-b), W12 (primitives), W15 (colors), W16 (layers).
- **Orphan-gated workstreams** (6): W05, W06, W07, W08, W09, W13 (responsive only), W14. Supervisor must dispatch a "is-this-file-live" verification step before any visualisation work, otherwise the preview will document dead code.

---

## 5. Phase 2 token-addition candidates <a id="phase-2-token-candidates"></a>

**Phase 0 does not add tokens.** This is the candidate list for the Phase 2 single-PR consolidation. Each entry: name, suggested raw value, source observation.

### 5.1 governance domain
- `--governance-bg-section` ← currently uses `--bg-2`; consider semantic alias `--color-bg-governance`. No new raw value needed.

### 5.2 paper-theme domain
- Lift the 32 hexes from `paper-theme.css` into `tokens/source.ts` as `paperOverrides: ThemeOverride[]`, mirroring the existing `lightOverrides` pattern. Names follow current `--bg-0/1/2/…`, `--fg-1/2/3/…`, `--brass-1/2/3`, `--ok/warn/err/info`, `--p-anthropic/moonshot/openai/xai`. No new token *names* — just override values codified in source.

### 5.3 ops domain
- `--ops-warn-soft` (raw `#fecaca`, source `ops.css:1`) — light-theme red tint for warning row.
- `--ops-info-soft` (raw `#cffafe`, source `ops.css:1`) — light-theme cyan tint for info row.

### 5.4 board / chat domain
- `--brand-vote-up` (raw `#ff4500`, source `board.css`, `dashboard.css`) — Reddit-style up-vote orange.
- `--link` (raw `#7193ff`) — generic link color, currently shared by board+dashboard.
- `--chat-bubble-self-bg`, `--chat-bubble-self-fg` (rose tints in `chat.css`).
- `--chat-bubble-peer-bg`, `--chat-bubble-peer-fg` (violet tints in `chat.css`).
- `--chat-bubble-system-bg` (cyan tint in `chat.css`).
- **Gate**: only add chat tokens if W08 verification confirms `chat.css` is being re-imported (currently orphan).

### 5.5 live-monitor / motion domain
- `--accent-violet` (raw `#a855f7`, source `live-monitor.css`) — pulse / activity highlight. Distinct from `--stalled`.

### 5.6 utility / variables migration (largest)
- Migrate all `variables.css` raw scales into `tokens/source.ts`:
  - slate-50 … slate-900 (10 entries)
  - purple-50 … purple-900 (already partially in source.ts, fold the remainder)
  - brick-50 … brick-900 (status-error scale)
  - brass scale (already partial)
  - paper scale
  - white-N opacity utilities (3, 4, 5, 6, 8, 10) — these are recipes, not tokens; keep as `:root` recipe but expose `--white-alpha-{05,10,20,…}` raw tokens.
- Total: ~25–30 new raw entries, all *codifying existing values* (not introducing new design intent).

### 5.7 spacing / radius scale extraction
- Identify the 24 px values in `variables.css` and propose `--space-{0,1,2,3,4,6,8}` + `--radius-{none,sm,md,lg,full}` if not already present in `tokens.generated.css`.
- Phase 2 only — no addition in Phase 0 or Phase 1.

### 5.8 z-index layer naming (W16)
- Existing tokens `--z-base/sticky/dropdown/overlay/drawer/modal/toast` (per SPEC §3) need `preview/layers.html` visualisation. No new tokens; preview-only.

---

## 6. CLAUDE.md governance note <a id="governance-note"></a>

The user-memory entry `feedback_tailwind-only-dashboard` (`memory/feedback_tailwind-only-dashboard.md`) declares:
> Preact `dashboard/`=Tailwind utility only. Bonsai `dashboard_bonsai/`=ppx_css only. **No handwritten CSS files**.

**Current production state violates this rule.** 19 hand-written CSS files ship under `dashboard/src/styles/` totalling 2 138 LOC. The drift is acknowledged in `dashboard/CSS-ARCHITECTURE.md` ("refactored from a single 2199-line `global.css` into a modular architecture") but never reconciled with the user memory.

### Recommended Phase 2 governance amendment
Add to `feedback_tailwind-only-dashboard.md` (or supersede it):

> **Exception**: domain-specific CSS files registered in `dashboard/design-system/preview/` are permitted. The preview gallery acts as the SSOT visualisation contract; any file not registered there is subject to deletion in the next CSS-architecture pass. `paper-theme.css` is permitted under the theme-override exception (data-theme attribute scoped).

This formalises the current state without rubber-stamping unbounded growth: every new hand-written CSS file must land with a preview page.

### Cross-reference
- `feedback_css-migration-delete-original` — applies to Phase 2 when migrating `variables.css` into tokens. The original file must be deleted in the same PR as the codegen output.
- `feedback_diagnostic_with_measurement_strongly_triggers_root_fix` — this audit deliberately includes per-file occurrence counts so follow-up workstreams can quote them in PR bodies.

---

## Appendix A — Audit reproduction

Scripts (kept under `/tmp/` during this branch; not committed):
- `/tmp/audit-css.sh` — naive per-file metrics (with comment noise).
- `/tmp/audit-hex-clean.sh` — comment-stripped global frequencies.
- `/tmp/audit-perfile-hex.sh` — per-file hex listings.
- `/tmp/audit-imports.sh` — import-trace.

Reproduction in a fresh checkout:
```sh
cd dashboard/src/styles
for f in *.css; do
  perl -0777 -pe 's{/\*.*?\*/}{}gs' "$f" > "/tmp/${f}"
done
cat /tmp/governance.css /tmp/paper-theme.css … | rg -o '#[0-9a-fA-F]{3,8}\b' | sort | uniq -c | sort -rn
```

## Appendix B — Orphan file confirmation method

```sh
rg -n "(chat|pipeline|live-monitor|keeper-detail|pixel-avatar|responsive|a11y)\.css" dashboard/ \
   -g '!*.css' -g '!node_modules'
# hits in: CSS-ARCHITECTURE.md (doc), main.ts:26 (commented-out), 2 JS comments
```

## Appendix C — Existing token coverage

`dashboard/design-system/tokens/source.ts` (854 LOC) defines 107 hex literals across raw/semantic/role tiers. `tokens.generated.css` (376 LOC) is the codegen output. Production references **`var(--*)` 297 times** against this catalogue, confirming the codegen pipeline is wired and consumed. The drift work is therefore **vocabulary expansion + dead-code triage**, not bootstrapping.

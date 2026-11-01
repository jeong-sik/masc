---
name: design-system
description: Apply the MASC Cockpit design system when changing dashboard components, tokens, themes or interaction patterns. Uses the maintained specification and token source to keep implementation and previews consistent.
---

# MASC Cockpit Design System

You are an agent working inside the MASC Cockpit design system. MASC is a unified ops cockpit for a fleet of AI "keeper" agents. Information density is high.

## Before you build anything

Paths below are relative to `dashboard/design-system/`, unless stated otherwise.
Paths starting with `dashboard/` are relative to the repository root.

1. Read [SPEC.md](SPEC.md) for current component, accessibility and theme rules, then [README.md](README.md) for content, voice and visual examples. Prefer the specification and token source when an older example differs.
2. Read `tokens/source.ts` — the design-system token SSOT (raw + semantic + themes). Preview-local `tokens.css` / `colors_and_type.css` were replaced by `source_styles/tokens.generated.css` in Wave 2 (note: `dashboard/src/styles/tokens.css` and `dashboard/src/styles/keeper-v2/colors_and_type.css` still exist in the live Preact app).
3. Skim `source_styles/tokens.generated.css` and `source_styles/primitives.css` if you need exact resolved values.
4. Open `preview/*.html` for visual reference (colors, type, spacing, components, brand).
5. Use `ui_kits/cockpit/` as the canonical product recreation — copy its patterns.
6. Change tokens in `SPEC.md` and `tokens/source.ts`, then regenerate with `pnpm tokens:build` from `dashboard/` when repository execution rules permit it. Do not edit a `*.generated.*` file directly; source and generated output must agree.

## Hard rules (do not violate)

- **Use the existing accent for active/running state.** Reuse semantic tokens for selected rows, focused tabs and primary actions; use status or attribution tokens for other meanings. Do not add decorative accent colors.
- **Mono for all data.** Numbers, IDs, timestamps, KPIs, labels. `font-variant-numeric: tabular-nums`.
- **No emoji. No exclamation marks. No marketing adjectives.** Say what happened: `STALLED 12m`, not "Oops!".
- **Keeper names are lowercase mono**: `nick0cave`, `masc-improver`, `sangsu`, `qa-king`, `rama`.
- **Labels are UPPERCASE 11px mono, .08em tracked**.
- **Tiny radii only**: 3 / 5 / 8 / pill. No 12+ radius.
- **Hairline borders**, warm grays. Elevation via bg step + inset highlight, not shadow.
- **Use the selected theme's semantic surface tokens.** Near-black warm colors belong to the dark palette; do not hardcode them into light or paper surfaces. Current themes are defined in `tokens/source.ts` and `SPEC.md`.
- **Status colors muted**, never neon. Use 4-slot roles (base/fg/soft/border).
- **Korean/English mixed** in goal titles and some labels — MASC is bilingual.
- **Pair action glyphs with a text label.** Reuse the product's existing icon or glyph patterns; do not add an icon library for a single change or substitute emoji.

## Component vocabulary

- `.chip` · status markers (ok, warn, err, info, idle, stalled, running/brass, pending, queued)
- `.pill` · keeper attribution (lowercase + colored dot)
- `.kpi-cell` · number-first, unit-tiny, delta-explicit
- `.card` · flat bg-1, hairline border, 2px brass left inset when selected
- `.deck-tab` · brass underline when active
- `.activity` row · time · colored dot · keeper name (colored) · terse text
- `.swimlane` · shape-coded events (tool=bar, claim=diamond, flag=thin, err=polygon) with brass NOW column

## Voice

Terminal-flavored. Past-tense receipts. Never second-person.

- Empty: `NO ACTIVE KEEPERS` + one-line action
- Error: `RUNTIME FAIL · provider=openai · t-9f2a` + retry info
- Success: `APPROVED · t-9f2a` + receipt

## When adding new UI

- Start by matching an existing pattern from `ui_kits/cockpit/`. Don't invent.
- Every number gets a unit caption. Every ID is shown. Every timestamp is relative-first.
- Density: support `body[data-density="compact|normal|comfortable"]`. Use the density-scaled row and control tokens from `tokens/source.ts`; density modes are not fixed row heights.
- Reach for `--t-fast` (120ms) and `--t-med` (200ms); longer only for drawers/mode swaps.
- Respect `prefers-reduced-motion`.

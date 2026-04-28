# MASC Cockpit Design System — Agent Skill

You are an agent working inside the MASC Cockpit design system. MASC is a single-pane-of-glass ops cockpit for a fleet of AI "keeper" agents. Information density is intentionally extreme.

## Before you build anything

1. Read `README.md` at the project root — it has the full content, voice, and visual foundations.
2. Read `tokens/source.ts` — the complete token SSOT (raw + semantic + themes). Hand-written `tokens.css` / `colors_and_type.css` were removed in Wave 2.
3. Skim `source_styles/tokens.generated.css` + `primitives.css` if you need exact resolved values.
4. Open `preview/*.html` for visual reference (colors, type, spacing, components, brand).
5. Use `ui_kits/cockpit/` as the canonical product recreation — copy its patterns.
6. New tokens go through SPEC.md PR → `source.ts` → `pnpm tokens:build` (never edit a `*.generated.*` file directly; the `tokens-drift` CI gate will reject it).

## Hard rules (do not violate)

- **Brass (`#d4a14a`) is for ONE thing per view.** Active row, focused tab, primary button, live KPI. Never for hover, never decorative.
- **Mono for all data.** Numbers, IDs, timestamps, KPIs, labels. `font-variant-numeric: tabular-nums`.
- **No emoji. No exclamation marks. No marketing adjectives.** Say what happened: `STALLED 12m`, not "Oops!".
- **Keeper names are lowercase mono**: `nick0cave`, `masc-improver`, `sangsu`, `qa-king`, `rama`.
- **Labels are UPPERCASE 11px mono, .08em tracked**.
- **Tiny radii only**: 3 / 5 / 8 / pill. No 12+ radius.
- **Hairline borders**, warm grays. Elevation via bg step + inset highlight, not shadow.
- **Near-black warm bg only**: `#0c0b08` page, `#141210/#1a1815/#211e1a/#2a2621` surfaces.
- **Status colors muted**, never neon. Use 4-slot roles (base/fg/soft/border).
- **Korean/English mixed** in goal titles and some labels — MASC is bilingual.
- **No icons alone** — always pair with a text label. No icon library. No emoji substitutes.

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
- Error: `CASCADE FAIL · provider=openai · t-9f2a` + retry info
- Success: `APPROVED · t-9f2a` + receipt

## When adding new UI

- Start by matching an existing pattern from `ui_kits/cockpit/`. Don't invent.
- Every number gets a unit caption. Every ID is shown. Every timestamp is relative-first.
- Density: support `body[data-density="compact|normal|comfy"]` — row heights 18/22/28px.
- Reach for `--t-fast` (120ms) and `--t-med` (200ms); longer only for drawers/mode swaps.
- Respect `prefers-reduced-motion`.

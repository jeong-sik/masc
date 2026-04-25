# MASC Cockpit Design System

> **MASC** is a dashboard-plus-IDE observation tool for managing a fleet of AI "keeper" agents. Information density is intentionally extreme — this is an ops cockpit, not a marketing page.

---

## What MASC is

MASC is a **single-pane-of-glass cockpit** where a human operator (or agent) can watch multiple AI keepers work in parallel across codebases, tasks, goals, and providers. It fuses two modes into one view:

- **Dashboard mode** — fleet ticker, KPI strip, lifeline heartbeat, swimlane timeline, ops rail, and a multi-tab "deck" (Board / Tasks / Goals / Verified / Providers / Sandbox / Cascade).
- **Code mode** — a 4-column IDE layer (tree · editor · review · activity) with stacked **observational overlays** (time · parallel · tools · approve · notes) that can explode into a 3D z-axis view.

The two modes can cohabit in **split mode**, sharing the topbar/ticker/KPI chrome.

### The fleet

Five named keeper personas show up throughout the UI with distinct colors:

| Keeper | Role | Color |
|---|---|---|
| **nick0cave** | Captain (delivery) | Brass `#d4a14a` |
| **masc-improver** | Improver | Green `#6b9e6b` |
| **sangsu** | Analyst | Blue `#6a8eb0` |
| **qa-king** | QA | Red `#c46a5a` |
| **rama** (ramarama) | Researcher | Purple `#8a6aa0` |

There are also supporting roles (scholar, janitor, issue_king, taskmaster, verifier, executor, velvet-hammer, ollama-local) and providers (Anthropic, Moonshot, OpenAI, xAI) that appear in the cascade chain and provider matrix.

### Goals seen in the system (Korean + English mixed)

- `goal-merge-blockers` — Merge-blocker 해결 및 CI 안정화
- `goal-keeper-clarity` — Keeper 활성화 및 선명성(Clarity) 파이프라인 개선
- `goal-masc-product` — MASC 프로덕트 레벨 에이전트 생태계 완성
- `goal-dashboard-goals-pr9712-followup` — Stabilize Goal Manager after PR #9712

MASC is **bilingual Korean/English** under the hood — titles, goals and some copy appear in Korean while IDs, tags, and chrome are English.

---

## Sources used

- **`styles/`** (read-only mount) — 14 CSS files defining the entire visual system. Copied into `source_styles/` as reference.
  - `tokens.css` — colors, type, spacing, elevation, motion, z-index, density
  - `primitives.css` — chip, pill, bar, spark, kv-row, btn variants, elevation helpers, status surfaces, animations
  - `layout.css` — the 3-col × 7-row cockpit grid
  - `sidebar.css` · `ticker.css` · `kpi.css` · `lifeline.css` · `center.css` · `swimlanes.css` · `deck.css` · `drawer.css` · `rail.css` — zone-specific styles
  - `code.css` · `layers.css` — code mode + stacked overlays
- **`.masc/`** (read-only mount) — runtime state/config directory: agent manifests, goals, tasks, activity events, auth, trajectories, trash. Used to derive copy, keeper names, and real goal/task strings. Not source of visuals.
- No Figma provided.
- No slide template provided — `slides/` is omitted per instructions.

---

## Content fundamentals

**Tone: terse, diagnostic, ops-flavored.** MASC talks like a mission-control console. Every label is doing a job.

- **Labels are ALL-CAPS mono**, small-caps letterspaced (.06–.08em): `FLEET` · `KEEPERS` · `NOW` · `TOOL USE` · `CASCADE` · `GOAL`.
- **Headings are numeric-first.** KPI values lead with the number; unit follows in a tiny caption: `1.24s TPS`, `87% PASS`.
- **IDs are always shown.** Tasks show `t-abc12`, goals show `goal-merge-blockers`, PRs show `#9712`. Mono, dim.
- **Timestamps are relative-first, absolute on hover.** `3m ago` · `2026-04-24 16:31:27Z`.
- **Bilingual on purpose.** Korean appears in goal titles, feature names, and some log lines; chrome labels stay English. Don't "translate everything."
- **No emoji. No exclamation marks.** The only affordance for attention is color (brass glow, err pulse) — never punctuation.
- **Second-person is rare; "you" barely appears.** The voice is third-person factual: "nick0cave claimed t-abc12" · "cascade hit at step 3."
- **No marketing words.** Never "delightful," "powerful," "beautiful." Say what happened: `STALLED 12m` · `3 FAIL / 47 PASS` · `TPS 1.24s (+0.1)`.
- **Status language is terminal-flavored.** `OK · FAIL · NOOP · ACTIVE · BLOCKED · STALLED · PENDING · DONE · RUNNING · IDLE`.
- **Keeper names are always lowercase mono.** `nick0cave`, never `Nick0Cave`.
- **Comments/review thread kinds** are a tight set: `QUESTION · FLAG · NOTE · APPROVE · SUGGEST`.

Examples seen in the system:

```
goal-merge-blockers       ACTIVE   3/3    priority 1
nick0cave  →  t-9f2a  tool.write_file  +18 −4   2m ago
CASCADE  anthropic > moonshot > openai   hit@2   1.24s
FLAG  @sangsu  drift detected at L187    +2 replies
```

---

## Visual foundations

**One-line summary:** dark brass ops terminal — almost-black warm bg, brass **only** for active/running state, muted status colors for data, grayscale for everything else, tiny radii, hairline borders, dense typography.

### Colors
- **Base: near-black with a 2–3% warm tint** (`--bg-0 #0c0b08`). Surfaces step up in ~5-point lightness jumps (`bg-1 #141210`, `bg-2 #1a1815`, `bg-3 #211e1a`, `bg-4 #2a2621`).
- **Brass is the ONE accent** (`#d4a14a`). Used ONLY for: running state, focused row, active tab underline, primary button, brand dot. **Never for hover, never for non-interactive emphasis.**
- **Status is desaturated, never neon.** `ok #6b9e6b`, `warn #c9a24a`, `err #c46a5a`, `info #6a8eb0`, `idle #6a6a6a`, `stalled #8a6aa0`. Each has a `*-fg`, `*-soft`, `*-border`, `*-ring` 4-slot role token.
- **Text never pure white.** `fg-1 #f0e9dc` is warm cream. Four steps down to `fg-4 #4a453e` for disabled.
- **Keeper colors = status colors, reused.** Fleet attribution piggybacks on brass/ok/info/err/stalled so the color language stays tight.

### Type
- **Mono-first.** JetBrains/SF Mono for numbers, IDs, timestamps, KPIs, code, labels. Sans only for body copy and titles.
- **Tabular numerals everywhere** (`font-variant-numeric: tabular-nums`). Essential for KPI rows that update live.
- **Small sizes.** Default body is `13px`. Labels are `11px uppercase`. Captions are `10px mono`. Hero KPIs are only `20–28px`.
- **Tight line heights.** `1.2` for chrome, `1.45` for body.

### Spacing & density
- **4px baseline** with an 8px alignment grid. Atomic scale `--sp-1 … --sp-8`.
- **Density is user-controllable** — `body[data-density="compact|normal|comfortable"]` multiplies `--density` (0.85 / 1 / 1.15) into row heights and control heights.
- **Row heights:** `micro 18px · tight 22px · default 26px · loose 32px · tall 40px`. Default rows are 22–26px — very dense.
- **Control heights:** `xs 16 · sm 20 · default 24 · lg 28`.

### Corners
- **Tiny radii.** `--r-1 3px` (most things), `--r-2 5px` (popovers), `--r-3 8px` (rare — drawer / modal). Pills are `999px`. This is an ops tool, not a consumer app.

### Borders
- **Hairline, warm.** Always 1px, always `--line-1/2/3` (warm neutral grays). Section dividers step up to `line-2` for emphasis and `line-3` between zones.
- **Cards have a border, not a shadow.** Elevation is carried by bg stepping + an inset highlight, not drop shadows.

### Elevation (7 steps)
Bundled as `--elev-0 … --elev-6` (bg + border + shadow). Low-level elements step bg color; higher levels add a subtle drop plus an inset `rgb(255 255 255 / .03)` 1px top highlight that reads as a "brushed metal" sheen. Modals go to 24px/64px shadows but still keep the inset highlight.

### Backgrounds & textures
- **Flat dark fills.** No gradients except the ticker's subtle top-to-bottom bg-1→bg-0 wash and protection gradients at ticker edges.
- **Dot-matrix grid** on the code editor scroll area — radial-gradient dots at 14px, 12% opacity brass. This is the one "texture" motif.
- **8px grid debug overlay** is built-in via `body[data-grid="1"]` — a crossed brass-tint grid for designer use.
- **No imagery.** No photos, no hero images, no illustrations. Data IS the content.

### Animation
- **Fast, functional, reduced-motion-respected.** `--t-fast 120ms · --t-med 200ms · --t-slow 360ms · --t-xslow 600ms`.
- **Easing set:** `ease cubic-bezier(.2,.7,.2,1)`, `ease-out`, `ease-in`, `ease-inout`, `ease-spring`.
- **Role presets:** `motion-enter · motion-exit · motion-swap · motion-reveal · motion-settle · motion-pop`.
- **Signature animation: the heartbeat.** `anim-heartbeat 1.4s` — double-beat scale pulse on the active keeper dot. Paired with `anim-pulse-glow` box-shadow throb on live KPI cells.
- **Glow-pulses per status:** err/warn/ok/info/stalled each have a matching `anim-pulse-*` that strobes their semantic color.
- **Shimmer for loading states** — linear-gradient swept across bg-2→bg-3.
- **Caret blink** — mono-block `▌` cursor on terminal-style UI.
- **`@media (prefers-reduced-motion: reduce)` collapses all durations to 1ms.**

### Hover states
- **Overlay, not tint.** `--hover-overlay: rgb(255 255 255 / .03)` layered on via gradient — preserves underlying color.
- **Brass on chrome, never on text.** Hovered keeper name doesn't turn brass; hovered tab underline does.
- **Scale on glyphs, not on rows.** Swimlane glyphs scale 1.5× on hover; rows just tint.

### Press/active states
- **Darker overlay.** `--active-overlay: rgb(0 0 0 / .25)`.
- **Selected rows get a 2px brass left border**, bg bumps to bg-3/bg-4, text stays fg-1.

### Focus ring
- **Brass double-ring.** `0 0 0 1px var(--brass-1), 0 0 0 3px rgb(brass/.25)`. Error focus swaps to err color.
- **Never blue system default.** Always overridden.

### Transparency & blur
- **Sparingly.** Scrims are `rgb(0 0 0 / .3/.5/.7)` (subtle/normal/strong).
- **Brass wash scrim** `rgb(brass-glow / .04)` behind the active region in exploded code view.
- **Backdrop blur** (`blur(4px)`) only on pinned note cards in the code overlay layer. Nothing else.

### Cards
- **Flat, bordered, bg-1 or bg-2.** No drop shadow at rest. Bumped to bg-3 with emphasized border on hover. Selected cards get a 2px brass inset bar on the left.
- **Cards have NO rounded-corner-with-colored-left-border accent** (an AI-slop trope) — the brass left border is a SELECTION indicator, not a decorative accent.

### Layout rules
- **Fixed chrome, scrolling center.** Topbar, ticker, KPI strip, lifeline, composer, and deck are all fixed-height grid tracks. Only the center pane scrolls.
- **12-column KPI grid** with min-width 72px per cell, horizontal scroll if cramped.
- **180px sidebar · 300px right rail.** Rail drops at `<1200px`, sidebar drops at `<900px` (but this is a desktop tool; phones are unsupported).
- **Tables are sticky-headed** with hairline row separators.

### The "now" metaphor
- **Vertical brass column spans all swimlanes** at the current time, with a linear-gradient top-to-bottom fade and a 4px brass glow. Optional pulse animation. This is the strongest visual element in the app — a single shining needle through time.

---

## Token tiers & theming

Tokens are arranged in three layers. Components should reference the
**semantic** layer when possible so theme overrides flow without
touching component CSS.

```
┌──────────────────────────────────────────────────────────────┐
│ raw         #0c0b08    #d4a14a    #6b9e6b                    │
│             --bg-0     --brass-1  --ok                       │
│ ▼                                                            │
│ semantic    --color-bg-page   --color-accent-fg              │
│             --color-fg-primary  --color-status-added         │
│             --color-keeper-1..5  --color-focus-ring          │
│ ▼                                                            │
│ component   .ix-tree { background: var(--color-bg-surface) } │
│             .chip   { color: var(--color-accent-fg) }        │
└──────────────────────────────────────────────────────────────┘
```

**Raw tier** — palette anchors. Defined in `source_styles/tokens.css` and
mirrored in `colors_and_type.css`. Treat as private-ish: prefer the
semantic alias unless you genuinely need a literal palette pick.

**Semantic tier** — meaning over hex. The full alias matrix:

| Alias | Maps to (dark default) | Used for |
|-------|------------------------|----------|
| `--color-bg-page` | `--bg-0` | top-level page bg |
| `--color-bg-surface` | `--bg-1` | resting panel / chrome |
| `--color-bg-elevated` | `--bg-2` | card / popover |
| `--color-fg-primary` | `--fg-1` | body text |
| `--color-fg-secondary` | `--fg-2` | label / dim text |
| `--color-fg-muted` | `--fg-3` | caption / disabled |
| `--color-border-default` | `--line-1` | hairline border |
| `--color-border-strong` | `--line-2` | emphasized border |
| `--color-accent` | `--brass-1` | active/running marker |
| `--color-accent-fg` | `--brass-1` | text/glyph on accent |
| `--color-status-added` | `--ok` | diff added / created |
| `--color-status-modified` | `--warn` | diff modified / at-risk |
| `--color-status-deleted` | `--err` | diff deleted / failed |
| `--color-keeper-1..5` | `--k-{nick,masc,sangsu,qa,rama}` | fleet attribution |
| `--color-focus-ring` | `--brass-1` | `:focus-visible` outline color |

**Component tier** — the actual component CSS. References semantic
aliases. Migrating a component from raw to semantic is a one-line swap.

### Theming

The system is **dark-by-design**. A `[data-theme="light"]` override
exists as foundation infrastructure for future surfaces but the dark
brass aesthetic remains the canonical look.

```js
import { setTheme, getTheme } from './preview/cb-shared.jsx';

setTheme('light');   // flips semantic aliases, persists to localStorage
setTheme('dark');    // explicit dark
setTheme(null);      // clear → falls back to prefers-color-scheme
```

The override only redefines the **semantic** alias values. Raw tokens
(`--bg-0`, `--brass-1`) keep their dark values. A component still using
raw tokens stays dark in light mode — this is intentional. Migration is
gradual: swap component CSS from raw to semantic and the theme starts
working for that component.

`@media (prefers-color-scheme: light)` is honored only when no explicit
`data-theme` is set, so a user's chosen theme is never overridden by OS
preference.

---

## Iconography

MASC uses **essentially no icons**. This is deliberate.

- **Text labels carry meaning.** Every affordance is named in small-caps mono text: `TOOL` · `CLAIM` · `FLAG` · `APPROVE`. No picture-only buttons.
- **Semantic glyphs, not icon set.** When a symbol is needed, it's a **Unicode character in mono** or a CSS-drawn shape:
  - `▌` — terminal caret (blinking)
  - `↩` — reply count prefix
  - `▲ ▼` — ticker up/down arrows
  - `>` — breadcrumb separator
  - Stars of David, chevrons, etc. — drawn with `clip-path` in CSS (e.g. the error glyph in `swimlanes.css`)
- **Dots as state.** 5–8px colored dots (`.dot`, `.dot-k-*`, `.sl-status`) are the primary "icon" vocabulary — status, keeper attribution, liveness.
- **Bars and sparks as glyphs.** `.bar`, `.spark`, `.tl-dot` — data-shaped markers that double as icons.
- **Shape-codes in swimlanes** — tool = filled bar, claim = diamond, text = thin line, noop = tick, error = jagged cross.
- **No icon font / no SVG sprite sheet in the codebase.** We don't import Lucide/Heroicons.
- **No emoji. Ever.**
- **Tree file icons** are a single monochrome mono character (`▸ ▾ · ƒ` etc.) in the tree-item — no colored file-type icons.

If new icons are genuinely needed (they usually aren't), **use Lucide at 12–14px, stroke 1.5, `color: currentColor`** and always pair with a text label — never icon-alone.

---

## Index — files in this design system

```
/
├─ README.md                    ← this file
├─ SKILL.md                     ← agent-skill manifest
├─ colors_and_type.css          ← CSS vars (base + semantic) + element defaults
├─ source_styles/               ← verbatim copies of the app's CSS (reference)
│   ├─ tokens.css  primitives.css  layout.css
│   ├─ sidebar.css  ticker.css  kpi.css  lifeline.css
│   ├─ center.css  swimlanes.css  deck.css  drawer.css
│   ├─ rail.css    code.css     layers.css
├─ preview/                     ← design-system cards (Colors / Type / Spacing / Components / Brand)
└─ ui_kits/
    └─ cockpit/                 ← the one product surface
        ├─ README.md
        ├─ index.html           ← interactive recreation of the MASC cockpit
        └─ *.jsx                ← Topbar, Ticker, KPIStrip, Lifeline, Sidebar,
                                  Swimlanes, Deck, Rail, Composer, Drawer, CodeMode
```

No `slides/` directory — no slide template was provided.

# Dashboard CSS Architecture

## Overview

The MASC Dashboard CSS has been refactored from a single 2199-line `global.css` file into a modular architecture using Tailwind v4's `@theme` and `@utility` directives.

## File Structure

### Foundation Files (Load Order)

1. **tokens.generated.css** (generated SSOT)
   - Tailwind v4 `@theme` design tokens
   - Source: `dashboard/design-system/tokens/source.ts` → `pnpm tokens:build`
   - Colors, typography scale, spacing, radii
   - Consumed by Tailwind utility classes and the 14 atom components
     (`chip`, `band`, `bar`, `btn`, `elev`, `focusable`, `kv-row`,
     `motion`, `section-head`, `sep`, `spark`, `surf`, `tk`)

2. **variables.css** (156 lines)
   - CSS custom properties (`:root`)
   - Legacy variable names for backward compatibility
   - Opacity variants, color utilities, z-index layers

3. **base.css** (40 lines)
   - Base HTML element styles
   - `html`, `body`, `#app` foundations
   - Global typography (links)

4. **keyframes.css** (114 lines)
   - All `@keyframes` animation definitions
   - Avatar animations, state transitions, component effects

5. **global.css** (1844 lines)
   - Reusable `@utility` blocks
   - Component-specific styles
   - Raw CSS for pseudo-elements and state selectors

### Component-Specific Files

- `ui.css` - Base UI components
- `agent-monitor.css` - Agent monitoring views
- `board.css` - Board/posts interface
- `chat.css` - Chat interface
- `command-swarm.css` - Command swarm UI
- `dashboard.css` - Dashboard layouts
- `governance.css` - Governance interfaces
- `governance-agent.css` - Agent governance
- `governance-keeper.css` - Keeper governance
- `ops.css` - Operations tab
- `roster.css` - Roster views
- `tools.css` - Tool interfaces

## Import Order (main.ts)

```typescript
// Foundation tokens (load first — see "Four-tier palette governance" below)
import './styles/tokens.generated.css'  // SSOT-1 (codegen, muted)
import './styles/tokens.css'            // SSOT-4 (Dark Brass canon)
import './styles/variables.css'         // SSOT-2 (live-surface bright)

// Layout primitives + zone shells
import './styles/primitives.css'
import './styles/layout.css'
import './styles/layers.css'
import './styles/kpi.css'
import './styles/lifeline.css'
import './styles/ticker.css'
import './styles/sidebar.css'
import './styles/rail.css'
import './styles/deck.css'
import './styles/drawer.css'
import './styles/swimlanes.css'
import './styles/code.css'
import './styles/center.css'
import './styles/base.css'
import './styles/keyframes.css'

// Global utilities and component-specific styles
import './styles/global.css'
import './styles/ui.css'
import './styles/board.css'
// ... (see main.ts for full list)

// Theme variant — activated on [data-theme="paper"]
import './styles/paper-theme.css'       // SSOT-3 (paper inversion)
```

The exact list evolves; treat `main.ts` as authoritative. The fixed
contract is **the first three lines** — token SSOTs must load before any
consumer.

## Design Patterns

### @utility Directive

Reusable utility classes are defined using Tailwind v4's `@utility` directive:

```css
@utility card {
  background: var(--card);
  border: 1px solid var(--card-border);
  border-radius: 12px;
  padding: 14px;
  &:hover { border-color: var(--border-slate-22); }
}
```

### Raw CSS Selectors

Some patterns require raw CSS and cannot be converted to utilities:

1. **Pseudo-elements** - `::before`, `::after`, `::marker`
2. **Attribute selectors** - `[open]`, `[data-*]`
3. **Complex compound selectors** - `.parent > .child`, `.class.modifier`
4. **Descendant selectors** - `.parent .child`

These are intentionally kept as raw CSS in their respective section files.

## Benefits

1. **Modularity** - Logical separation of concerns
2. **Maintainability** - Easier to locate and update specific styles
3. **Performance** - Better tree-shaking and caching
4. **Standards** - Uses Tailwind v4 best practices
5. **Documentation** - Clear section headers and comments

## Line Count Comparison

- **Before**: 2199 lines (single file)
- **After**:
  - Foundation: 361 lines (4 files)
  - Global: 1844 lines
  - Components: 832 lines (13 files)
  - **Total**: 3037 lines

The increase reflects better organization with headers, comments, and logical separation.

## Four-tier palette governance (DS-Drift Phase 2 finding, 2026-04-28; SSOT-4 documented 2026-05-11)

DS-Drift Phase 1 audit (PR #11300, #11317) and Track C-β investigation
(closed without commit) established that the dashboard runs **four
intentionally separate color SSOTs**, not one SSOT with drift. The
fourth (`tokens.css` "Dark Brass") was the active token canon since
Design System V2 (PR #12625) but was not documented when this section
was first written.

### SSOT-1: `tokens/source.ts` -> `tokens.generated.css` (muted canon)

- Codegen-driven, Tailwind v4 `@theme` form
- "Status — muted, desaturated. Never neon. Locked canon." (source.ts)
- Brass/warm-led palette; muted greens/ambers/reds for status
- 79 named hex tokens, governed by `pnpm tokens:build`

### SSOT-2: `dashboard/src/styles/variables.css` (live-surface bright)

- Hand-written, loads **after** tokens.generated.css (cascades over)
- Tailwind 400/500 family: `--ok: #4ade80`, `--warn: #fbbf24`, `--bad: #ef4444`, `--accent: #47b8ff`
- variables.css comment confirms: "visual fidelity prefers consistency
  with the live surface over the SPEC source's muted palette"
- 40 hex defs; alpha ladders (`--accent-6/-8/-10/-12/-15/-18/-20/-30/-36/-45`),
  RGB triplets for `rgb()/.alpha` syntax, semantic alias (`--bg-root`,
  `--text-strong`, `--accent-soft` etc.)
- Consumed by 30+ production CSS files via `var(--accent)` etc.

**Naive `var()` substitution from variables.css to source.ts tokens
shifts rendered colors** (RGB distance 7-96 between namesakes). This is
a feature, not drift. Track C-beta was closed as no-op for this reason.

### SSOT-3: `dashboard/src/styles/paper-theme.css` (paper theme variant)

- Activated via `?theme=paper` or `localStorage.dashboardTheme = "paper"`
- Scoped under `[data-theme="paper"]`
- Source: "Anyang Sleepers Design System (colors_and_type.css)" — the
  paper inversion of MASC. Maps every semantic role to warm-paper tokens
- 32 unique hex (paper/ink/forest/brass/brick/ember/slate/plum/teal
  family x 4 stop)
- Currently bridges to the existing `--color-*` semantic vars so enabling
  the theme swaps the palette with **zero component edits**
- Lift to `tokens/source.ts` (as a "paper" theme chapter via codegen) is
  a valid Phase 2 follow-up but not required — the file is already the
  paper-theme SSOT in its own right

### SSOT-4: `dashboard/src/styles/tokens.css` (Dark Brass canon)

- Hand-written, 489 LOC, 53 hex defs, header: "MASC Cockpit — Dark Brass tokens"
- Loads as the **second** foundation import in `main.ts`,
  **between `tokens.generated.css` and `variables.css`** in cascade
  (tokens.generated → tokens.css → variables.css → ...)
- Defines the `--bg-0..4`, `--fg-1..4`, `--line-1..3`, `--brass-1..3`,
  `--brass-glow` namespace consumed by 28+ CSS files via `var(--bg-2)` etc.
- Distinct from SSOT-2 (`variables.css`): SSOT-4 is **chrome canon**
  (surfaces, borders, text steps, brass accent for active state); SSOT-2
  is **status canon** (`--ok`, `--warn`, `--bad`, `--accent` and alpha
  ladders for live-surface bright palette)
- Origin: PR #12625 "Design System V2 (Semantic Theme System)";
  PR #12769 "design-system token migration — full drift elimination";
  PR #12881 "5 polish tokens"; PR #12922 "provider color tokens"
- Comment in source: *"bg is almost-black with 2-3% warm tint. Brass
  accent used ONLY for active/running state. Status colors reserved for
  data, never chrome. Everything else is grayscale."*

### Cascade order vs. SSOT label

The SSOT numbers are **labels (chronological discovery order)**, not
load positions. Actual cascade order in `main.ts`:

| Position | File | SSOT label |
|----------|------|------------|
| 1 | `tokens.generated.css` (first import) | SSOT-1 |
| 2 | `tokens.css` (second import) | SSOT-4 |
| 3 | `variables.css` (third import) | SSOT-2 |
| 4..N | component CSS files | — |
| last CSS import | `paper-theme.css` (after all component CSS) | SSOT-3 |

Later positions cascade over earlier ones for any shared selector. SSOT-3
is `[data-theme="paper"]` scoped, so it only activates on attribute set.

### Phase 2 work classification matrix

| Hex source | Action | Reason |
|------------|--------|--------|
| `tokens.generated.css` | none (codegen output) | source.ts is the SSOT |
| `tokens.css` | preserve as Dark Brass canon, document | SSOT-4, see below |
| `variables.css` | preserve as bright SSOT, document | intentional two-tier overlay |
| `paper-theme.css` | preserve OR lift-to-codegen (valid both) | paper variant SSOT |
| `chat.css`, `board.css`, `ops.css`, `dashboard.css`, `global.css`, `a11y.css`, `base.css`, `live-monitor.css` raw hex | resolved as of 2026-05-11 — 0 raw hex remaining in CSS layer (PRs #12769, #12881, #12922) | drift purge complete |
| Component inline hex (`dashboard/src/components/**/*.ts`) | new surface — see "Component inline hex policy" below | Mermaid/Cytoscape/SVG cannot resolve CSS vars |

## Component inline hex policy (2026-05-11)

Some libraries used by `dashboard/src/components/**/*.ts` cannot resolve
CSS custom properties at render time and require **literal hex values**
in JavaScript:

| Library / context | Reason `var(--token)` fails | Example file |
|-------------------|------------------------------|--------------|
| Mermaid `classDef` / `style` | Mermaid renders SVG strings; CSS vars in attribute values are not resolved by the rendering pipeline | `harness-health.ts`, `composite-fsm-flowchart.ts` |
| Cytoscape style API | Style objects are JS literals; `'#xxxxxx'` required | `common/cytoscape-fsm.ts` |
| Canvas 2D / SVG `fill` set via JS | When fill is set programmatically, the browser does not resolve CSS vars from the JS string | `git-graph-view.ts`, `activity-heatmap-draw.ts` |

For these surfaces, the convention is:

```ts
// Example: literal hex mirrors the resolved CSS token value.
// Production components often use SSOT-1/SSOT-2 aliases
// (e.g. --color-bg-surface → --bg-1); the comment must name
// the ultimate canonical token so drift detection can resolve it.
const PANEL_BG = '#1a1815'   // --bg-2 (SSOT-4 tokens.css)
const STATUS_OK = '#6b9e6b'   // --ok   (SSOT-4 tokens.css)
```

### Required mirror format

When a component declares an inline hex that mirrors a CSS token, the
**same line or the line immediately above** must contain a comment of
the form `--token-name` (with the leading two hyphens). This makes the
mirror machine-parseable for drift-detection lint.

### Risks

- **Silent drift**: a designer changes `--bg-2` in `tokens.css` from
  `#1a1815` to a new hue; the inline mirror in `harness-health.ts` stays
  at the old hex; the Mermaid graph renders in a stale color forever.
  The comment makes it *look* synced.
- **Approximation creep**: a comment like `// --color-bg-3 (navy approx)`
  documents intentional drift. These need an explicit escape marker
  (e.g., `// --color-bg-3 (approx, do not auto-fix)`) so a lint can
  skip them without false-fixing.

### Lint plan (RFC-OAS-018 candidate, deferred)

A drift-detection lint script would:

1. For each `'#[0-9a-fA-F]{6}'` literal in `dashboard/src/components/**/*.ts`,
   require either the mirror-comment format or an explicit `// no-token`
   marker.
2. For each mirror, look up the token in the four SSOT files and
   compare hex values.
3. Fail CI on mismatch; allow `// approx` to opt out.

The lint follows the file-level grep pattern established in
RFC-0063 §7-B (`scripts/ci/check-drain-loop-yields.sh`).

A structural alternative — typed mirror codegen (e.g. `mirrorOf('--bg-2')`
with compile-time token lookup or a codemod that verifies the resolved hex
against the canonical SSOT) — is noted as a future RFC-OAS-018 direction
to avoid the string-prefix whitelist accumulation risk of `// approx` labels.

## Preview gallery — SPA hash routing (2026-04-28)

`dashboard/design-system/preview/components.html` is a React 18 SPA
loaded by `cb-root.jsx` + 12 `cb-group-*.jsx` modules. Native anchor
scroll silently no-ops because the canvas (`DCViewport`) uses
`transform: pan/zoom` inside `overflow:hidden`.

`cb-root.jsx` includes a `HashBridge` component (lines 10-29) that
listens for `hashchange` events and routes the hash into `setFocus`
on the design canvas context. As a result, all `components.html#xxx`
anchor links from `preview/index.html` work correctly — they focus
the first artboard slot of the matched section.

Audited 21 anchor IDs (`ide-backbone, ide-tree, ide-edit, ide-pr,
ide-graph, ide-term, goal-zone, task-zone, account, board-zone, msgs,
composer-v2, cascade, audit, safe-auto, cost, heur, keeper-v2,
decisions, episodes, autoresearch`) — all present in cb-*.jsx and
functional via HashBridge. **Do not assume "SPA = anchors broken"
without checking HashBridge first.**

## Related

- Issue #3915 - CSS refactoring
- Issue #3912 - Duplicate CSS removal (predecessor)
- Tailwind v4 documentation: https://tailwindcss.com/docs/v4-beta
- DS-Drift Phase 0 audit: `dashboard/design-system/audits/2026-04-28-production-css-drift.md`
- DS-Drift orphan triage: `dashboard/design-system/audits/2026-04-28-orphan-triage.md`
- DS-Drift Phase 3 refresh (CSS layer 0 hex remaining): see this file's commit history (2026-05-11)
- SSOT-4 (`tokens.css`) origin PRs: #12625 (V2), #12769 (drift elimination), #12881 (polish tokens), #12922 (provider tokens)
- RFC-0063 §7-B file-level grep lint pattern (precedent for component inline hex lint)

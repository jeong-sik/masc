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
// Foundation styles (load first)
import './styles/tokens.generated.css'
import './styles/variables.css'
import './styles/base.css'
import './styles/keyframes.css'

// Global utilities and layout
import './styles/global.css'

// Component-specific styles (alphabetically)
import './styles/[component].css'
```

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

## Two-tier palette governance (DS-Drift Phase 2 finding, 2026-04-28)

DS-Drift Phase 1 audit (PR #11300, #11317) and Track C-β investigation
(closed without commit) established that the dashboard runs **two
intentionally separate color SSOTs**, not one SSOT with drift.

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

### Phase 2 work classification matrix

| Hex source | Action | Reason |
|------------|--------|--------|
| `tokens.generated.css` | none (codegen output) | source.ts is the SSOT |
| `variables.css` | preserve as bright SSOT, document | intentional two-tier |
| `paper-theme.css` | preserve OR lift-to-codegen (valid both) | paper variant SSOT |
| `chat.css`, `board.css`, `ops.css`, `dashboard.css`, `global.css`, `a11y.css`, `base.css`, `live-monitor.css` raw hex (~22 total) | individual review per hex — `var()` if mapping exists, otherwise leave with TODO | true drift candidates |

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

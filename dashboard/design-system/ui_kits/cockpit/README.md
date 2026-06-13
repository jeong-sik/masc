# MASC Cockpit — UI Kit

Interactive recreation of the MASC single-pane cockpit. One HTML, React-driven, split into a small set of JSX modules.

## Surfaces covered

- **Topbar** — brand · goal switcher · mode tabs (Dashboard / Code / Split) · density toggle · build stamp
- **Ticker** — scrolling fleet events (continuous mono tape)
- **KPI Strip** — 6 live cells, one "live" cell glows brass
- **Lifeline** — 60s heartbeat sparkline
- **Sidebar** — Fleet list with keeper heartbeats + Goals list
- **Swimlanes** — 5 keepers × timeline with brass "now" column
- **Deck** — tab group (Board / Tasks / Goals / Verified / Providers / Runtime) with content
- **Rail** — activity feed + runtime trace
- **Composer** — keeper.claim() input
- **Status Bar** — build + online providers
- **Planes / Crew / Drawer / Focus / WidgetSolo / StatusTray** — extended surfaces (multi-plane layout with a reachable Crew mode, multi-keeper crew, slide-out drawer, focus overlay, single-widget solo view, status tray)

## Files

### Entry & styles
- `index.html` — entry, loads React + Babel + all modules
- `cockpit.css` — cockpit-specific styles (imports tokens.css + primitives.css)
- `cockpit-ext.css` / `cockpit-ext.jsx` / `cockpit-ext.js` — extension overlay surfaces
- `components.css` — component-scoped styles
- `primitives.css` — primitive-token CSS layer
- `tokens.generated.css` — generated design-token CSS (output of `pnpm tokens:build`)
- `drawer.css`, `focus-mode.css`, `status-tray.css`, `widget-solo.css` — surface-specific styles

### Seed data
- `data.js` — Phase 1 seed data (keepers, goals, tasks, events, providers, runtime)
- `data-p2.js` — Phase 2 synthetic seed data (branches, nudges, board posts, messages, audit, costs, decisions, episodes)
- `data-crew.js` — empty synthetic crew seed; repository previews must not embed `.masc` dumps

### App shell
- `App.jsx` — root layout + state (mode, density, selected keeper/goal)
- `Chrome.jsx` — `Topbar` · `Ticker` · `KpiStrip` · `Lifeline` (top-of-screen surfaces)
- `Panels.jsx` — `Sidebar` · `Swimlanes` · `Deck` · `Rail` · `Composer` · `StatusBar` (main work area)
- `Planes.jsx` — multi-plane (Work / Comms / Observe / Cognition / IDE) layout
- `CrewPlane.jsx` — Crew plane shell (multi-keeper inspector grid, no repository-shipped live dump)

### Surface components
- `Drawer.jsx` — slide-out drawer (terminal / inspector surfaces; referenced by RFC 0025)
- `FocusMode.jsx` — focus-mode overlay
- `StatusTray.jsx` — bottom status tray
- `WidgetSolo.jsx` — single-widget solo surface

### Shared primitives & component groups
- `cb-shared.jsx` — shared telemetry primitives (Heartbeat, Sparkline, …); sourced by `src/cb-shared-telemetry-source.test.ts` for telemetry-fabrication guards
- `cb-group-{d,e,f,h,i,j,k}.jsx` — grouped component sets; each file bundles related components to keep the module count low

## Notes

- Surfaces are grouped into shared JSX files (`Chrome.jsx`, `Panels.jsx`, `cb-group-*.jsx`) rather than one file per surface — related components share a file to keep the module count low.
- All components publish themselves on `window` so Babel-compiled scripts can use them without explicit imports.
- Seed data in `data.js`, `data-p2.js`, and `data-crew.js` is synthetic. Do not mirror `.masc/` records, keeper prompts, runtime profile names, decision logs, or operator transcripts into repository previews. For a per-component design library see `../../preview/components.html`.
- Consolidated from the previously parallel `dashboard/cockpit-kit/` standalone build on 2026-05-13. RFC 0013 references this directory as the migration source for the KpiStrip / Lifeline / Ticker production ports.

# MASC Cockpit — UI Kit

Interactive recreation of the MASC single-pane cockpit. One HTML, React-driven, split into a small set of JSX modules.

## Surfaces covered

- **Topbar** — brand · goal switcher · mode tabs (Dashboard / Code / Split) · density toggle · build stamp
- **Ticker** — scrolling fleet events (continuous mono tape)
- **KPI Strip** — 6 live cells, one "live" cell glows brass
- **Lifeline** — 60s heartbeat sparkline
- **Sidebar** — Fleet list with keeper heartbeats + Goals list
- **Swimlanes** — 5 keepers × timeline with brass "now" column
- **Deck** — tab group (Board / Tasks / Goals / Verified / Providers / Cascade) with content
- **Rail** — activity feed + cascade trace
- **Composer** — keeper.claim() input
- **Status Bar** — build + online providers

## Files

- `index.html` — entry, loads React + Babel + all modules
- `cockpit.css` — cockpit-specific styles (imports tokens.css + primitives.css)
- `data.js` — Phase 1 seed data (keepers, goals, tasks, events, providers, cascade)
- `data-p2.js` — Phase 2 seed data (branches, nudges, board posts, messages, audit, costs, decisions, episodes, autoresearch — sourced from real `.masc/*` records)
- `App.jsx` — root layout + state (mode, density, selected keeper/goal)
- `Chrome.jsx` — `Topbar` · `Ticker` · `KpiStrip` · `Lifeline` (top-of-screen surfaces)
- `Panels.jsx` — `Sidebar` · `Swimlanes` · `Deck` · `Rail` · `Composer` · `StatusBar` (main work area)

## Data knobs

- `MASC_DATA.status_tray_thresholds.fail_urgent` controls when the status tray promotes failure events to urgent. Fallback: `3`.
- `MASC_DATA.status_tray_thresholds.cascade_info` controls when cascade events become the KPI spotlight. Fallback: `2`.

## Notes

- Surfaces are grouped into two JSX files (`Chrome.jsx` and `Panels.jsx`) rather than one file per surface — small, related components share a file to keep the module count low.
- All components publish themselves on `window` so Babel-compiled scripts can use them without explicit imports.
- Seed data in `data.js` and `data-p2.js` mirrors real `.masc/` records (fleet IDs, goal IDs, board posts, decisions, autoresearch loops). For a per-component design library see `../../preview/components.html`.

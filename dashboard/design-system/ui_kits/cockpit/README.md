# MASC Cockpit — UI Kit

Interactive recreation of the MASC single-pane cockpit. One HTML, React-driven, split into small JSX modules.

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
- `App.jsx` — root layout + state
- `data.js` — seed data (keepers, goals, tasks, events, providers)
- `Topbar.jsx`, `Ticker.jsx`, `KpiStrip.jsx`, `Lifeline.jsx`
- `Sidebar.jsx`, `Swimlanes.jsx`, `Deck.jsx`, `Rail.jsx`, `Composer.jsx`, `StatusBar.jsx`

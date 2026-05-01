# Connector UI — Design Principles

Companion to `CONNECTOR-CONFIG-SCHEMA.md` (data) and
`SIDECAR-LIFECYCLE-API-RFC.md` (transport). This document captures the
design rules the dashboard's `connectors` surface holds itself to, so
future PRs don't drift back into menu-driven, click-heavy UX.

**Audience**: anyone touching the connector surface, which today spans:

- `connector-status.ts` — ConnectorLivePanel, ConnectorStatusPanel (root)
- `connector-overview-strip.ts` — at-a-glance 4-tile strip + `ConnectorBulkActions`
- `connector-readiness-rail.ts` — 4-pill status rail + per-pill inflight tracker
- `connector-config-form.ts` — schema-driven form + Save + 🔄 Restart
- `connector-quick-bind.ts` — inline channel↔keeper binding form
- `connector-binding-summary.ts` — humanized bindings list + × unbind
- `connector-onboarding.ts` — cold-start 4-card grid + bulk Start All
- `sidecar-log-viewer.ts` — inline 📋 log tail per sidecar
- `sidecar-startup-watch.ts` — "⚠ 기동 응답 없음" banner + log jump
- `setup-guide-card.ts` + `connector-setup-guides.ts` — per-sidecar setup walkthrough

**SSOT for the actual code**: the components named above. This doc
explains *why* they look the way they do — code is the *what*.

---

## 1. Status visible at a glance

> A fresh operator opens `/connectors` and within one screen knows
> what is broken and what they can click to fix it.

- Each card carries a 4-pill **ConnectorReadinessRail**
  (Token / Process / Gate / Bindings). Each pill encodes its state
  with **color + glyph + text** — never color-only (color blindness +
  screen readers).
- The all-connectors view (`section=connector-status`) gets a
  **ConnectorOverviewStrip** above the stacked detail panels: 4
  brand-colored mini cards each with a rail. Operator scans the strip
  before scrolling.
- Per-bridge deep links now stay on `section=connector-status` and use
  `connector=<id>` to select the relevant card. Old
  `section=connector-discord` style links redirect into that picker.

## 2. Inline action over menu navigation

> Clicking the broken pill *does* the fix, doesn't just *navigate* to it.

- Token pill click → opens `⚙ Config` form for the same connector
  (lazy schema fetch).
- Process pill click → toggles Start ↔ Stop based on current state.
- Gate pill click → expands the header detail panel (liveness dots).
- Bindings pill click → smooth-scrolls to keepers section
  (`#keepers-<id>` anchor).
- The Save button on the config form spawns its own restart hint
  ("🔄 재시작") next to the saved-at timestamp — the next thing the
  operator needs to do is one click away from the change that
  motivated it.

## 3. Triple feedback for in-flight actions

> Click → immediately visible response → fade to confirmed state.

`withRailInflight(connectorId, key, asyncFn)` wraps each rail-triggered
async action. While the action is in flight the pill:

- Pulses (`animate-pulse`).
- Swaps the dot glyph to `…`.
- Swaps detail text to "진행 중...".
- Sets `disabled=true` (blocks double-click race like stop+start).

Only async pills (Process today) are wired. Synchronous pills
(open form, scroll) skip the wrapper because pulse-then-instant-clear
flickers without conveying anything.

## 4. Additive, never destructive

> A new surface is added without removing the surface a familiar
> operator already knows.

- Phase 7 IA promotion: connectors moved out of `operations`, but the
  legacy `?section=operations&view=connectors` URL still resolves
  via a redirect in `operations-panel.ts`.
- Overview strip rendered *above* the existing stacked detail panels,
  not *replacing* them.
- Rail sits *above* the existing toggle buttons (📋 Logs / ⚙ Config /
  ▾ details) — those toggles still work for operators who learned
  them before the rail existed.

## 5. Brand color + emoji shared across every surface

> Discord is blurple everywhere. iMessage is green everywhere.

`connectorAccentStyle(id)` and `channelIcon(id)` from
`connector-status.ts` are imported by:

- `connector-onboarding.ts` (cold-start grid)
- `connector-overview-strip.ts` (live grid)
- `connector-status.ts` itself (full per-connector card)

Adding a 5th sidecar means one entry in `KNOWN_CONNECTOR_IDS` plus
one row each in the accent + emoji tables — no per-surface re-styling.

## 6. Single source of truth, even for derived state

> Two health checks for the same fact create two answers.

- **Token validity** is *not* a separate `/api/v1/sidecar/validate-token`
  call. It is derived from `connector.available` — if the sidecar booted
  successfully, the token validated. The bridge would have crashed at
  startup otherwise.
- **Connector list** = exactly 4 ids in `KNOWN_CONNECTOR_IDS` (matches
  backend whitelist in `lib/server/server_routes_http_routes_sidecar.ml`
  via the `known_ids size = 4` invariant test). Never compute the list
  from "what the gate is currently advertising" — that's empty during
  cold start.

## 7. Best-effort vs strict fetches

> A failure to fetch supplementary info should not block the primary
> view; a failure to fetch primary info should be visible.

- `fetchSchema` (config form) is *strict*: 4xx/5xx surfaces a red
  inline error with retry button. Without the schema, the form has
  no fields to render.
- `fetchCurrentValues` (config prefill) is *best-effort*:
  4xx/5xx/exception silently returns `{}` so the form falls back to
  schema defaults. Pre-fill is a convenience, not a requirement.

## 8. Wire components via DOM IDs, not props

> Cross-card coordination uses well-known anchor IDs +
> `scrollIntoView`, not React/Preact context.

- Overview-strip tile click → `document.getElementById('connector-card-discord').scrollIntoView()`.
- Rail Bindings pill click → `document.getElementById('keepers-discord').scrollIntoView()`.
- `scroll-mt-4` on the target so smooth-scroll lands below any
  sticky-ish header.

This keeps the component graph one-directional: overview-strip
imports rail; rail does NOT import overview-strip. Cycles avoided.

## 9. Per-pill state granularity

> Don't lock the whole rail when one async action is running.

`inflightState: Record<connectorId, Partial<Record<RailKey, true>>>`.
- Lookup: `getRailInflight(id)[key] === true`
- Mutation always via `mark` / `clear` helpers (or `withRailInflight`)
  so signal updates remain unidirectional.
- Wrong shape that we explicitly avoided: a global `actionLoading`
  boolean — too coarse, it would gray out the Bindings pill while
  Start is in flight.

## 10. Backend graceful degradation

> Dashboard ships ahead of backend endpoints; missing endpoints
> degrade visibly without crashing.

- POST `/api/v1/sidecar/start` 404 → toast.error, rail returns to
  bad state, no white-screen.
- GET `/api/v1/sidecar/schema` 503 → form renders inline error +
  retry button (operator can start sidecar then retry).
- GET `/api/v1/sidecar/config` 4xx → form silently falls back to
  schema defaults (best-effort fetch, see §7).

This is what lets the dashboard PR (#7833) merge before the backend
PR (#7831) without breaking the live dashboard.

---

## What this surface does NOT do (and shouldn't)

- **Auto-restart after Save**. A typo'd token saved + auto-restart
  means instant outage. Operator clicks "🔄 재시작" deliberately.
- **Hot-reload running sidecars**. Pydantic re-reads TOML at process
  start, not on file change. Restart is the documented behavior.
- **Validate token format client-side**. Each bridge has different
  rules; relying on schema + actual sidecar boot is the SSOT.
- **Persist editor state to localStorage**. The form is operator
  workspace, not durable data. Reload should re-fetch from disk
  (current values = SSOT).

---

## Symmetric surfaces — every action has a reverse

Components that introduce a forward action ship its inverse in the
same spatial region so operators don't have to relearn where the
undo lives:

| Forward | Inverse | Location |
|---------|---------|----------|
| QuickBindForm (bind a channel) | × button in BindingSummary row | same card, 1 row apart |
| Start All (bulk spawn) | Stop All (bulk SIGTERM) | OverviewStrip header + OnboardingGrid |
| Save config | 🔄 Restart | ConfigForm, same row as Save |
| Process pill click → Start | Process pill click → Stop | same pill, toggles by state |

This is the "additive, never destructive" principle (§4) applied at
the action level — discovering the undo shouldn't require a different
mental model than discovering the do.

---

## Adding a 5th connector — checklist

1. Add id to `KNOWN_CONNECTOR_IDS` (dashboard) + `known_ids` (backend
   `server_routes_http_routes_sidecar.ml`).
2. Add row to `CONNECTOR_DISPLAY_NAMES`, `CONNECTOR_ACCENT_RGB`,
   `SIDECAR_DIRS`, `channelIcon` switch.
3. Add `sidecars/<id>-bot/` with: `src/config.py` (BotConfig),
   `src/schema_dump.py` (one-line `python -m`), `run.sh`
   ([start|stop|tail|status]).
4. Add `CONNECTOR_SETUP_GUIDES['<id>']` (token-acquisition steps).
5. Update `test_known_ids_size_matches_dashboard` invariant to expect 5.

If any of these are skipped the dashboard will draw a card the
backend refuses to spawn — the invariant test catches it before merge.

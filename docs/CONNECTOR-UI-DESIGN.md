# Connector UI — Design Principles

Companion to `CONNECTOR-CONFIG-SCHEMA.md` (data). This document captures the
design rules the dashboard's `connectors` surface holds itself to, so
future PRs don't drift back into menu-driven, click-heavy UX.

**Audience**: anyone touching the connector surface, which today spans:

- `connector-status.ts` — ConnectorLivePanel, ConnectorStatusPanel (root)
- `connector-overview-strip.ts` — at-a-glance strip, one mini card per connector
- `connector-readiness-rail.ts` — 4-pill status rail
- `connector-config-form.ts` — ⚙ Config panel listing the env vars a connector needs
- `connector-quick-bind.ts` — inline channel↔keeper binding form
- `connector-onboarding.ts` — cold-start card grid
- `setup-guide-card.ts` + `connector-setup-guides.ts` — per-connector setup walkthrough
- `connector-constants.ts` — display names, accent colors, icons

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
- The all-connectors view (`section=connector-status`) renders a
  **ConnectorOverviewStrip** above the detail panel: one brand-colored mini
  card per connector, each with a rail. Operator scans the strip before
  scrolling.
- The `?connector=<id>` query parameter narrows the view to one connector
  for deep links.

## 2. Inline action over menu navigation

> Clicking the broken pill goes to the place that fixes it.

- Token pill click → opens the `⚙ Config` panel for the same connector.
- Process and Gate pill clicks → expand the card's header detail panel.
- Bindings pill click → smooth-scrolls to the keepers section
  (`#keepers-<id>` anchor).
- On the overview strip, the Token pill opens the same panel; the Process,
  Gate and Bindings pills select that connector and scroll to the detail panel.

## 3. Brand color + emoji shared across every surface

> Discord is blurple everywhere. iMessage is green everywhere.

`connectorAccentStyle(id)` and `channelIcon(id)` from
`connector-constants.ts` are used by:

- `connector-onboarding.ts` (cold-start grid)
- `connector-overview-strip.ts` (live grid)
- `connector-status.ts` (full per-connector card)
- `connector-keeper-matrix.ts` (`channelIcon`)

Adding a connector means one entry in `KNOWN_CONNECTOR_IDS` plus
one row each in the accent + emoji tables — no per-surface re-styling.

## 4. Single source of truth, even for derived state

> Two health checks for the same fact create two answers.

- The **Token** and **Process** pills both read `gatewayAvailable` (the
  connector's `available` flag). No separate token-validation call exists.
- **Connector list** = the ids in `KNOWN_CONNECTOR_IDS`
  (`dashboard/src/config/connector-ids.ts`). Never compute the list from
  "what the gate is currently advertising" — that's empty during cold start.

## 5. Wire components via DOM IDs, not props

> Cross-card workspace collaboration uses well-known anchor IDs +
> `scrollIntoView`, not React/Preact context.

- Overview-strip tile click →
  `document.getElementById('connector-detail-panel').scrollIntoView()`.
- Rail Bindings pill click →
  `document.getElementById('keepers-<id>').scrollIntoView()`.

This keeps the component graph one-directional: overview-strip
imports rail; rail does NOT import overview-strip. Cycles avoided.

---

## Adding a connector — checklist

1. Add the id to `KNOWN_CONNECTOR_IDS` (`dashboard/src/config/connector-ids.ts`).
2. Add a row to `CONNECTOR_DISPLAY_NAMES`, `CONNECTOR_ACTIVATION`,
   `CONNECTOR_ACCENT_RGB` and `CHANNEL_ICONS` (`connector-constants.ts`).
3. Add `IN_PROCESS_CONFIG_GUIDES[<id>]` and a `FIELD_HINTS` row for each of its
   env vars (`connector-config-form.ts`).
4. Add `CONNECTOR_SETUP_GUIDES['<id>']` (`connector-setup-guides.ts`).

The gateway the card shows runs inside the MASC server, in
`lib/server/server_<id>_in_process_gateway.ml`.

`connector-constants.test.ts` fails when a known id has no display name or no
activation requirement. The accent and icon tables fall back to a neutral
default, so a missing row there fails nothing.

# RFC 0013 — Cockpit-to-Production Migration (KpiStrip · Lifeline · Ticker)

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation), RFC 0008
  (AgentPresence — Lifeline / KpiStrip subscribe), IDE Chrome tokens
  (#11948), Stage 1.4 chrome tokens (#11965).
- **Implements**: spec §5.5.1 (Stage 5).
- **Sister RFC**: RFC 0014 IdePlane assembly (planned follow-up
  combining all P0/P1 primitives into the 3-pane layout).

---

## 1. Motivation

Spec §1.3.2 / §4.1 / §5.5.1 record the **largest single gap** in the
design system: the `dashboard/design-system/ui_kits/cockpit/` UI Kit
contains 13 high-fidelity components — KpiStrip, Lifeline, Ticker,
Composer, StatusBar, IdePlane and others — built as standalone
HTML+React+Babel prototypes. None of them ship in the production
Preact dashboard.

The three highest-leverage components are KpiStrip (8-cell live KPI
strip), Lifeline (60 s heartbeat sparkline), and Ticker (real-time
event tape). They are the *operational headline*: an operator's
first-glance answer to "is the fleet healthy". Today production has
none of the three — operators must navigate to per-keeper detail
views to assemble the same picture.

This RFC defines a **single migration plan** for the three components
in priority order, each as an independent PR following the Strangler
Fig pattern from RFC 0002. The plan freezes scope, lists token + ARIA
contracts, and documents the data-source bridge (SSE + AgentPresence)
so the implementation PRs can run sequentially without re-deriving
context.

## 2. Non-Goals

- Migrate the *other* 10 cockpit UI Kit components (Composer,
  StatusBar, Sidebar, Swimlanes, Deck, Rail, App shell, Topbar,
  Mode tabs, IdePlane). Each gets its own RFC or follows in a v0.6+
  bundle. This RFC scopes to the three "headline" components.
- Implement IdePlane. IdePlane is the 3-pane layout that *contains*
  the editor surface; it depends on RFC 0003 (Roving Tabindex), RFC
  0004 (SplitPane), and RFC 0011 (InlineSuggestion) implementations.
  It earns its own RFC after those land.
- Replace existing dashboard layout. Production keeps its current
  routing; the three new components mount inside the existing
  topbar / overview-pane chrome.

## 3. Migration order and rationale

| Order | Component | Reason |
|---|---|---|
| 1 | **KpiStrip** | Lowest dependency footprint; static-shape grid; tokens already exist (`--type-display`, `--brass-glow`). Validates the cockpit→production port path before harder components. |
| 2 | **Lifeline** | Builds on KpiStrip's surface conventions. Subscribes to `AgentPresenceManager` (RFC 0008) once that lands. SVG-based; deterministic render given same input. |
| 3 | **Ticker** | Requires SSE event-tape stream (server-side prep needed). Async + animated; biggest test surface. Ships after the other two settle. |

## 4. KpiStrip migration

### 4.1 Source (cockpit UI Kit)

`dashboard/design-system/ui_kits/cockpit/components/KpiStrip.jsx`:

- 8 cells: Tokens/sec, Pass Rate, Fails, Cascade Hits, Open PRs,
  Active Keepers, Stalled, Goal Progress.
- Each cell renders as `--type-display` (36 px mono) value + small
  `--type-meta` (10 px) label.
- "Live" cells (Active Keepers, Stalled) get brass glow via
  `--color-accent-glow` (existing token).
- React + Babel prototype, no real data source.

### 4.2 Target (production)

`dashboard/src/components/cockpit/kpi-strip.tsx` — Preact + Tailwind
v4 + headless data hook.

```tsx
// dashboard/src/components/cockpit/kpi-strip.tsx
export interface KpiCell {
  readonly id: string;
  readonly label: string;
  readonly value: string;          // pre-formatted ("42%", "1,203/s")
  readonly trend?: "up" | "down" | "flat";
  readonly live?: boolean;         // brass glow
  readonly severity?: "ok" | "warn" | "err";
}

export function KpiStrip({ cells }: { readonly cells: ReadonlyArray<KpiCell> }) {
  return (
    <ol
      role="list"
      aria-label="Fleet KPIs"
      class="flex gap-[var(--sp-region)] overflow-x-auto"
    >
      {cells.map((c) => (
        <li
          key={c.id}
          role="listitem"
          class="kpi-cell"
          data-live={c.live ? "" : undefined}
          data-severity={c.severity}
        >
          <span class="text-[length:var(--type-meta)] text-[color:var(--color-fg-muted)]">
            {c.label}
          </span>
          <span class="text-[length:var(--type-display)] tabular-nums">
            {c.value}
          </span>
        </li>
      ))}
    </ol>
  );
}
```

### 4.3 Data source

A thin hook `useKpiStream()` subscribes to the existing
`/api/dashboard/metrics` SSE channel and returns the latest 8 cells.
Hook lives in `dashboard/src/hooks/use-kpi-stream.ts`. Stream details
are server-side scope.

### 4.4 Tokens

All values via existing tokens. **No new tokens needed**:

- `--type-display`, `--type-meta` (Type Role)
- `--color-fg-muted`, `--color-fg-primary`
- `--color-accent-glow` for `data-live` cells (brass)
- `--ok-fg`, `--warn-fg`, `--err-fg` for `data-severity`

### 4.5 ARIA

- `role="list"` + `aria-label="Fleet KPIs"` on the strip.
- Each cell `role="listitem"`.
- Live cells additionally get `aria-live="polite"` so SR users hear
  KPI updates without spamming (`aria-atomic="false"` on each cell).

## 5. Lifeline migration

### 5.1 Source

`ui_kits/cockpit/components/Lifeline.jsx` — 60 s SVG sparkline of
fleet heartbeat (one tick per second).

### 5.2 Target

`dashboard/src/components/cockpit/lifeline.tsx` — Preact + SVG.
Subscribes to `AgentPresenceManager` (RFC 0008). One color band per
active keeper, derived from `agent.colorSlot`.

### 5.3 Determinism

For the same input data, the SVG `path` `d` attribute must be
byte-identical across renders. This is required for snapshot-test
parity. The path generator lives in
`dashboard/src/components/cockpit/lifeline-path.ts` as a pure
function (60 ticks → SVG `d` string).

### 5.4 Anomaly state

When the global heartbeat drops below threshold, the strip's
background flips to `--color-status-err` and the strip emits an
SR announcement via the consumer's `role="status"` region (the same
region used for AgentPresence state changes).

### 5.5 Tokens

Existing only:

- `--color-bg-page`, `--color-bg-surface`
- `--color-status-ok`, `--color-status-err`
- `--k-1` … `--k-12` for per-keeper bands

### 5.6 ARIA

- `role="img"` with `aria-label="Fleet heartbeat, last 60 seconds,
  N active keepers"` (label updates with active count).
- The visible SVG itself is purely decorative; the human-readable
  state is in the `aria-label`.

## 6. Ticker migration

### 6.1 Source

`ui_kits/cockpit/components/Ticker.jsx` — infinite horizontal slide
of recent fleet events. Mono font, brass key event highlight.

### 6.2 Target

`dashboard/src/components/cockpit/ticker.tsx` — Preact + CSS
`@keyframes ticker-slide`. Subscribes to a new
`/api/dashboard/events` SSE stream (server-side prep needed).

### 6.3 Performance

The ticker animation must not re-layout on every event. Animation
runs against `transform: translateX(...)`; new events are appended
to a ring buffer (≤ 50 entries). Old entries fall off via
animation, not DOM removal; DOM cleanup runs every 30 s.

### 6.4 `prefers-reduced-motion`

The slide animation pauses when the OS flag is set. Consumer adds:

```css
@media (prefers-reduced-motion: reduce) {
  .ticker-track { animation: none; }
}
```

…and the ticker switches to a *static* tail-of-N most-recent display
when paused. No content disappears.

### 6.5 Tokens

Existing only — `--type-meta`, `--color-fg-secondary`,
`--color-accent-glow` for highlighted events.

### 6.6 ARIA

- `role="log"` + `aria-live="polite"` + `aria-atomic="false"`. Each
  event item is announced once on add (announce buffering matches
  the manager pattern from RFC 0007 Toast).
- `aria-label="Fleet event ticker"` on the region.

## 7. Cross-cutting test plan

For each component:

- **Visual snapshot** — stable across reruns given the same inputs.
- **Data subscription** — SSE / AgentPresence subscription + clean
  unmount (no listener leak).
- **Reduced motion** — animation paths short-circuit when flag set.
- **`jest-axe`** — passes on the standard fixture (1 strip × 8 cells,
  Lifeline with 5 keepers, Ticker with 10 events).
- **Token compliance** — `rg -F 'hex(' dashboard/src/components/cockpit/`
  returns zero hand-coded hexes.

## 8. Migration sequencing

Each component is **one PR**. Order:

1. PR `feature/cockpit-kpi-strip` — KpiStrip + `useKpiStream` hook +
   server SSE channel doc reference.
2. PR `feature/cockpit-lifeline` — Lifeline + path generator + tests.
3. PR `feature/cockpit-ticker` — Ticker + new event SSE stream
   handler + reduced-motion fallback.

Each PR ships with the cockpit UI Kit's prototype copy (in
`ui_kits/cockpit/components/`) **untouched** — the prototype stays as
the visual reference for future tuning. Production code is the new
canonical source.

## 9. Merge criteria (RFC level)

- [ ] Reviewer agrees with migration order (KpiStrip → Lifeline →
      Ticker)
- [ ] Token contracts §4.4, §5.5, §6.5 confirmed (no new tokens)
- [ ] ARIA contracts §4.5, §5.6, §6.6 confirmed
- [ ] Server-side SSE channels for Lifeline + Ticker scoped (out of
      this RFC, but blocker for impl PRs 2 and 3)
- [ ] CHANGELOG entry under v0.5 lists the planned 3-PR series

## 10. Open questions

1. **Live KPI re-announce frequency** — every value change vs every
   N seconds? Spam vs staleness trade-off. Current proposal: rate-
   limit to 1 announce per 5 s per cell; Toast-style dedup.
2. **Ticker buffer size** — 50 events × ~50 px each ≈ 2500 px wide.
   Fine on desktop; mobile-narrow may need smaller. Confirm.
3. **Lifeline determinism vs animation** — should the path animate
   in (60-tick stride-fade) or just snap? Snap is cheaper + easier
   to snapshot-test. Current proposal: snap on first paint, animate
   only the *delta* (newest tick) on each update.

These do not block draft acceptance but must close before the first
implementation PR opens.

// MASC Dashboard — runtime telemetry sub-panel.
//
// Hosts the four "infra/billing/audit" views that previously lived inline in
// runtime-panel.ts: `cost`, `audit`, `heuristics`, `stress`. Today they all
// dispatch to the same CostDashboard component (it sub-routes on the view
// key); this module just owns the view-set membership predicate and the
// thin render wrapper so runtime-panel.ts can ask "is this a telemetry view"
// without enumerating the labels itself.
//
// Behavior is unchanged from the previous inline form: URLs, cockpit aliases
// (audit / hr-log / hr-st / hr-mod / ct-agt / ct-mtx / ct-lat), and chip
// strip layout (Primary vs Advanced) all stay where they are. This is a
// pure structural extraction so a future PR can grow the telemetry surface
// (richer dispatch, dedicated tabs, separate store) without touching
// runtime-panel.

import { html } from 'htm/preact'
import { CostDashboard, type CostView } from './cost-dashboard'

// Telemetry-panel handles only the four "infra/billing/audit" subkeys of
// CostView (CostView itself includes `decisions`, which this panel does
// NOT render). Extract narrows the closed set so callers spreading
// TELEMETRY_VIEW_CHIPS into RuntimeView-typed strips stay sound.
export type TelemetryView = Extract<CostView, 'cost' | 'audit' | 'heuristics' | 'stress'>

// Single SSOT for the four telemetry chip definitions. Host components
// import this list to render the Advanced chip strip — the labels live
// next to the dispatch logic instead of being duplicated in runtime-panel.
export const TELEMETRY_VIEW_CHIPS: ReadonlyArray<{ key: TelemetryView; label: string }> = [
  { key: 'cost', label: '비용 / 지연' },
  { key: 'audit', label: '감사' },
  { key: 'heuristics', label: '휴리스틱' },
  { key: 'stress', label: '스트레스' },
]

const TELEMETRY_VIEW_SET: ReadonlySet<TelemetryView> = new Set<TelemetryView>(
  TELEMETRY_VIEW_CHIPS.map(chip => chip.key),
)

export function isTelemetryView(view: string): view is TelemetryView {
  return TELEMETRY_VIEW_SET.has(view as TelemetryView)
}

export function TelemetryPanel({ view }: { view: TelemetryView }) {
  return html`<${CostDashboard} view=${view} />`
}

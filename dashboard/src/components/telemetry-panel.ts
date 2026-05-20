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

const TELEMETRY_VIEW_SET: ReadonlySet<CostView> = new Set<CostView>([
  'cost',
  'audit',
  'heuristics',
  'stress',
])

export function isTelemetryView(view: string): view is CostView {
  return TELEMETRY_VIEW_SET.has(view as CostView)
}

export function TelemetryPanel({ view }: { view: CostView }) {
  return html`<${CostDashboard} view=${view} />`
}

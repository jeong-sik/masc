// Fleet Health Panel — Phase 2 unified view for fleet-health section.
// Replaces the Phase 1 interim FleetHealthRouter with FilterChips-based
// view switching. Default view shows event-log + tool-quality side-by-side.
// Deep-link view param (?view=comparison) selects a single sub-view.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { route } from '../router'
import { FilterChips } from './common/filter-chips'
import { TelemetryUnified } from './telemetry-unified'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { ToolQualityPanel } from './tool-quality-panel'
import { GovernanceMonitor } from './governance-monitor'

export type FleetHealthView = 'default' | 'event-log' | 'comparison' | 'tool-quality' | 'governance'

const FLEET_VIEWS: FleetHealthView[] = ['default', 'event-log', 'comparison', 'tool-quality', 'governance']

function isFleetView(v: string | undefined): v is FleetHealthView {
  return !!v && (FLEET_VIEWS as string[]).includes(v)
}

// Derive the active view from route params. Single source of truth — no
// local writable signal needed. FilterChips uses the `value` prop (read-only)
// + `onChange` to update the URL, which flows back through the route signal.
const activeView = computed<FleetHealthView>(() => {
  const v = route.value.params.view
  return isFleetView(v) ? v : 'default'
})

const VIEW_CHIPS: Array<{ key: FleetHealthView; label: string }> = [
  { key: 'default',      label: '개요' },
  { key: 'event-log',    label: '이벤트 로그' },
  { key: 'comparison',   label: 'Keeper 비교' },
  { key: 'tool-quality', label: '도구 품질' },
  { key: 'governance',   label: '거버넌스' },
]

function updateViewParam(view: FleetHealthView) {
  const hash = view === 'default'
    ? '#monitoring?section=fleet-health'
    : `#monitoring?section=fleet-health&view=${view}`
  history.replaceState(null, '', hash)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

function DefaultDualPanel() {
  return html`
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <div class="min-w-0 overflow-hidden">
        <${TelemetryUnified} />
      </div>
      <div class="min-w-0 overflow-hidden">
        <${ToolQualityPanel} />
      </div>
    </div>
  `
}

export function FleetHealthPanel() {
  const view = activeView.value

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-medium text-[var(--text-strong)]">Keeper 현황</h2>
      </div>
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />
      <div class="transition-opacity duration-200">
        ${view === 'default'
          ? html`<${DefaultDualPanel} />`
        : view === 'event-log'
          ? html`<${TelemetryUnified} />`
        : view === 'comparison'
          ? html`<${FleetTelemetryPanel} />`
        : view === 'tool-quality'
          ? html`<${ToolQualityPanel} />`
        : html`<${GovernanceMonitor} />`}
      </div>
    </div>
  `
}

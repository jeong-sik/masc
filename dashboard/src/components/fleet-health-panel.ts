// Fleet Health Panel — Phase 2 unified view for fleet-health section.
// Replaces the Phase 1 interim FleetHealthRouter with FilterChips-based
// view switching. Default view shows event-log + tool-quality side-by-side.
// Deep-link view param (?view=comparison) selects a single sub-view.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { replaceRoute, route } from '../router'
import { FilterChips } from './common/filter-chips'
import { TelemetryUnified } from './telemetry-unified'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { ToolQualityPanel } from './tool-quality-panel'
import { GovernanceMonitor } from './governance-monitor'
import { AttributionPanel } from './attribution-panel'
import { KeeperReactivityMonitor } from './keeper-reactivity-monitor'

type FleetHealthView = 'default' | 'event-log' | 'comparison' | 'tool-quality' | 'governance' | 'attribution' | 'keeper-health'

const FLEET_VIEWS: FleetHealthView[] = ['default', 'event-log', 'comparison', 'tool-quality', 'governance', 'attribution', 'keeper-health']

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
  { key: 'default',        label: '개요' },
  { key: 'event-log',      label: '이벤트 로그' },
  { key: 'comparison',     label: 'Keeper 비교' },
  { key: 'tool-quality',   label: '도구 품질' },
  { key: 'governance',     label: '거버넌스' },
  { key: 'attribution',    label: 'Attribution' },
  { key: 'keeper-health',  label: '반응성 모니터' },
]

function updateViewParam(view: FleetHealthView) {
  replaceRoute(
    'monitoring',
    view === 'default'
      ? { section: 'fleet-health' }
      : { section: 'fleet-health', view },
  )
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
    <div class="contain-content flex flex-col gap-4">
        <div class="flex flex-col gap-1">
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">운영 신호 묶음</div>
          <p class="m-0 text-xs leading-paragraph text-[var(--color-fg-muted)]">
            이 화면은 roster가 아니라 이벤트, 비교, 도구 품질, 거버넌스 같은 플릿 신호를 보는 곳입니다.
          </p>
        </div>
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />
      <div class="transition-opacity duration-[var(--t-med)]">
        ${view === 'default'
          ? html`<${DefaultDualPanel} />`
        : view === 'event-log'
          ? html`<${TelemetryUnified} />`
        : view === 'comparison'
          ? html`<${FleetTelemetryPanel} />`
        : view === 'tool-quality'
          ? html`<${ToolQualityPanel} />`
        : view === 'governance'
          ? html`<${GovernanceMonitor} />`
        : view === 'keeper-health'
          ? html`<${KeeperReactivityMonitor} />`
        : html`<${AttributionPanel} />`}
      </div>
    </div>
  `
}

// RuntimePanel — Phase 4 runtime section with FilterChips toggle.
// Wraps OasHealthChip, RuntimeMonitor, PrometheusMetrics with view switching.
// Views: default (all), providers (health + monitor), prometheus (metrics only).
// Pattern: mirrors fleet-health-panel.ts (unidirectional flow via URL).

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { route } from '../router'
import { FilterChips } from './common/filter-chips'
import { OasHealthChip } from './oas-health-chip'
import { RuntimeMonitor } from './runtime-monitor'
import { PrometheusMetrics } from './prometheus-metrics'

export type RuntimeView = 'default' | 'providers' | 'prometheus'

const RUNTIME_VIEWS: RuntimeView[] = ['default', 'providers', 'prometheus']

function isRuntimeView(v: string | undefined): v is RuntimeView {
  return !!v && (RUNTIME_VIEWS as string[]).includes(v)
}

const activeView = computed<RuntimeView>(() => {
  const v = route.value.params.view
  return isRuntimeView(v) ? v : 'default'
})

const VIEW_CHIPS: Array<{ key: RuntimeView; label: string }> = [
  { key: 'default', label: '전체' },
  { key: 'providers', label: '프로바이더' },
  { key: 'prometheus', label: '메트릭' },
]

function updateViewParam(view: RuntimeView): void {
  const hash = view === 'default'
    ? '#monitoring?section=runtime'
    : `#monitoring?section=runtime&view=${view}`
  history.replaceState(null, '', hash)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

export function RuntimePanel() {
  const view = activeView.value

  return html`
    <div class="flex flex-col gap-4">
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
      />
      <div class="grid gap-4">
        ${view === 'providers'
          ? html`
            <${OasHealthChip} />
            <${RuntimeMonitor} />
          `
        : view === 'prometheus'
          ? html`<${PrometheusMetrics} />`
        : html`
            <${OasHealthChip} />
            <${RuntimeMonitor} />
            <${PrometheusMetrics} />
          `}
      </div>
    </div>
  `
}

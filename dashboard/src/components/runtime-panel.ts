// RuntimePanel — Phase 4 runtime section with FilterChips toggle.
// Wraps OasHealthChip, RuntimeMonitor, CascadeConfigPanel, PrometheusMetrics,
// VerificationSpecsPanel with view switching.
//
// Progressive-disclosure default view (density reduction, 2026-04):
//   Signal layer     — OasHealthChip always expanded (summary StatCells)
//   Diagnostic layer — Cascade, Providers & Models via CollapsibleSection (closed)
//   Raw layer        — Prometheus metrics, Formal specs via CollapsibleSection (closed)
// NN/g progressive disclosure: respect working-memory limits, defer detail.
//
// Explicit drill-down via FilterChips remains unchanged:
//   default    — Signal strip + collapsed diagnostic/raw accordions
//   cascade    — cascade config + health only (설정 ↔ 실측)
//   providers  — OAS health chip + runtime monitor only
//   prometheus — raw Prometheus metrics only
//   verification — formal specs only
// Pattern: mirrors fleet-health-panel.ts (unidirectional flow via URL).

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { route } from '../router'
import { FilterChips } from './common/filter-chips'
import { CollapsibleSection } from './common/collapsible'
import { OasHealthChip } from './oas-health-chip'
import { RuntimeMonitor } from './runtime-monitor'
import { PrometheusMetrics } from './prometheus-metrics'
import { CascadeConfigPanel } from './cascade-config-panel'
import { VerificationSpecsPanel } from './verification-specs-panel'

type RuntimeView = 'default' | 'cascade' | 'providers' | 'prometheus' | 'verification'

const RUNTIME_VIEWS: RuntimeView[] = ['default', 'cascade', 'providers', 'prometheus', 'verification']

function isRuntimeView(v: string | undefined): v is RuntimeView {
  return !!v && (RUNTIME_VIEWS as string[]).includes(v)
}

const activeView = computed<RuntimeView>(() => {
  const v = route.value.params.view
  return isRuntimeView(v) ? v : 'default'
})

const VIEW_CHIPS: Array<{ key: RuntimeView; label: string }> = [
  { key: 'default', label: '전체' },
  { key: 'cascade', label: 'Cascade' },
  { key: 'providers', label: '프로바이더' },
  { key: 'prometheus', label: '메트릭' },
  { key: 'verification', label: '형식검증' },
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
    <div class="flex flex-col gap-4" role="region" aria-label="Runtime 패널">
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
      />
      <div class="grid gap-4">
        ${view === 'cascade'
          ? html`<${CascadeConfigPanel} />`
        : view === 'providers'
          ? html`
            <${OasHealthChip} />
            <${RuntimeMonitor} />
          `
        : view === 'prometheus'
          ? html`<${PrometheusMetrics} />`
        : view === 'verification'
          ? html`<${VerificationSpecsPanel} />`
        : html`
            <${OasHealthChip} />
            <${CollapsibleSection} id="runtime-details-cascade" title="Cascade">
              <${CascadeConfigPanel} />
            <//>
            <${CollapsibleSection} id="runtime-details-providers" title="프로바이더">
              <${RuntimeMonitor} />
            <//>
            <${CollapsibleSection} id="runtime-details-prometheus" title="메트릭">
              <${PrometheusMetrics} />
            <//>
            <${CollapsibleSection} id="runtime-details-verification" title="형식검증">
              <${VerificationSpecsPanel} />
            <//>
          `}
      </div>
    </div>
  `
}

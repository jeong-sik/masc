// RuntimePanel — Phase 4 runtime section with FilterChips toggle.
// Wraps OasHealthChip, RuntimeMonitor, CascadeConfigPanel, PrometheusMetrics,
// VerificationSpecsPanel with view switching.
//
// Progressive-disclosure default view (density reduction, 2026-04):
//   Signal layer     — OasHealthChip always expanded (summary StatCells)
//   Diagnostic layer — Cascade, Providers & Models in <details> (closed)
//   Raw layer        — Prometheus metrics, Formal specs in <details> (closed)
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

const SUMMARY_CLASS =
  'cursor-pointer select-none rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-2 text-sm font-medium text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)] marker:text-[var(--text-muted)]'

const DETAILS_CLASS = 'group rounded border border-[var(--card-border)] bg-transparent'

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
            <details class=${DETAILS_CLASS} data-testid="runtime-details-cascade">
              <summary class=${SUMMARY_CLASS}>Cascade</summary>
              <div class="p-3 border-t border-[var(--card-border)]">
                <${CascadeConfigPanel} />
              </div>
            </details>
            <details class=${DETAILS_CLASS} data-testid="runtime-details-providers">
              <summary class=${SUMMARY_CLASS}>프로바이더</summary>
              <div class="p-3 border-t border-[var(--card-border)]">
                <${RuntimeMonitor} />
              </div>
            </details>
            <details class=${DETAILS_CLASS} data-testid="runtime-details-prometheus">
              <summary class=${SUMMARY_CLASS}>메트릭</summary>
              <div class="p-3 border-t border-[var(--card-border)]">
                <${PrometheusMetrics} />
              </div>
            </details>
            <details class=${DETAILS_CLASS} data-testid="runtime-details-verification">
              <summary class=${SUMMARY_CLASS}>형식검증</summary>
              <div class="p-3 border-t border-[var(--card-border)]">
                <${VerificationSpecsPanel} />
              </div>
            </details>
          `}
      </div>
    </div>
  `
}

// RuntimePanel — Phase 4 runtime section with FilterChips toggle.
// Wraps OasHealthChip, RuntimeMonitor, PrometheusMetrics,
// VerificationSpecsPanel with view switching.
//
// Progressive-disclosure default view (density reduction, 2026-04):
//   Signal layer     — OasHealthChip always expanded (summary StatCells)
//   Diagnostic layer — Providers & Models via CollapsibleSection (closed)
//   Raw layer        — Prometheus metrics, Formal specs via CollapsibleSection (closed)
// NN/g progressive disclosure: respect working-memory limits, defer detail.
//
// Explicit drill-down via FilterChips remains unchanged:
//   default      — Signal strip + collapsed diagnostic/raw accordions
//   providers    — OAS health chip + runtime monitor only
//   cost         — model/keeper cost and latency only
//   audit        — dashboard audit ledger
//   heuristics   — heuristic firing log + coverage by module
//   stress       — agent stress events
//   inspector    — cascade strategy trace/provider health drill-down
//   prometheus   — raw Prometheus metrics only
//   verification — formal specs only
// Pattern: mirrors fleet-health-panel.ts (unidirectional flow via URL).

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { replaceRoute, route } from '../router'
import { FilterChips } from './common/filter-chips'
import { CollapsibleSection } from './common/collapsible'
import { OasHealthChip } from './oas-health-chip'
import { RuntimeMonitor } from './runtime-monitor'
import { PrometheusMetrics } from './prometheus-metrics'
import { VerificationSpecsPanel } from './verification-specs-panel'
import { CostDashboard, type CostView } from './cost-dashboard'
import { CascadeInspector } from './cascade-inspector'
import { RouteLink } from './common/route-link'

type RuntimeView =
  | 'default'
  | 'providers'
  | 'cost'
  | 'audit'
  | 'heuristics'
  | 'stress'
  | 'inspector'
  | 'prometheus'
  | 'verification'

const RUNTIME_VIEWS: RuntimeView[] = [
  'default',
  'providers',
  'cost',
  'audit',
  'heuristics',
  'stress',
  'inspector',
  'prometheus',
  'verification',
]

function isRuntimeView(v: string | undefined): v is RuntimeView {
  return !!v && (RUNTIME_VIEWS as string[]).includes(v)
}

const activeView = computed<RuntimeView>(() => {
  const v = route.value.params.view
  return isRuntimeView(v) ? v : 'default'
})

const VIEW_CHIPS: Array<{ key: RuntimeView; label: string }> = [
  { key: 'default', label: '전체' },
  { key: 'providers', label: '런타임' },
  { key: 'cost', label: '비용 / 지연' },
  { key: 'audit', label: '감사' },
  { key: 'heuristics', label: '휴리스틱' },
  { key: 'stress', label: '스트레스' },
  { key: 'inspector', label: '검사기' },
  { key: 'prometheus', label: '메트릭' },
  { key: 'verification', label: '형식검증' },
]

function costDiagnosticView(view: RuntimeView): CostView | null {
  return view === 'cost' || view === 'audit' || view === 'heuristics' || view === 'stress'
    ? view
    : null
}

function updateViewParam(view: RuntimeView): void {
  replaceRoute(
    'monitoring',
    view === 'default'
      ? { section: 'runtime' }
      : { section: 'runtime', view },
  )
}

function CascadeConfigCanonicalLink() {
  return html`
    <section
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      aria-label="Cascade canonical surface"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="text-sm font-semibold text-text-strong">Cascade Config</div>
          <div class="mt-1 max-w-2xl text-xs leading-relaxed text-text-muted">
            Providers, models, and routing rules are managed in the dedicated Cascade Config surface.
          </div>
        </div>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'cascade-config' }}
          class="inline-flex min-h-9 items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2 text-xs font-semibold text-text-strong transition-colors hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-elevated)]"
        >
          Open Cascade Config
        <//>
      </div>
    </section>
  `
}

function HiddenDiagnosticsLinks() {
  const links = [
    {
      label: 'Transport diagnostics',
      detail: 'SSE/gRPC/WebSocket/WebRTC connection freshness.',
      section: 'transport-health',
    },
    {
      label: 'Doctor',
      detail: 'Sidecar, base-path, and config diagnostics.',
      section: 'doctor',
    },
    {
      label: 'Feature cleanup',
      detail: 'Feature flag rollout, inactive, and deprecated states.',
      section: 'feature-health',
    },
  ]
  return html`
    <section
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      aria-label="Hidden diagnostics"
    >
      <div class="flex flex-col gap-3">
        <div>
          <div class="text-sm font-semibold text-text-strong">Diagnostics</div>
          <div class="mt-1 max-w-2xl text-xs leading-relaxed text-text-muted">
            These are routeable support surfaces, not primary Monitor lanes. Use them when a keeper-facing runtime incident points at infrastructure or stale rollout state.
          </div>
        </div>
        <div class="grid gap-2 md:grid-cols-3">
          ${links.map(link => html`
            <${RouteLink}
              key=${link.section}
              tab="monitoring"
              params=${{ section: link.section }}
              class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2 transition-colors hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-elevated)]"
            >
              <span class="block text-xs font-semibold text-text-strong">${link.label}</span>
              <span class="mt-1 block text-2xs leading-relaxed text-text-muted">${link.detail}</span>
            <//>
          `)}
        </div>
      </div>
    </section>
  `
}

export function RuntimePanel() {
  const view = activeView.value
  const costView = costDiagnosticView(view)

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
        : costView
          ? html`<${CostDashboard} view=${costView} />`
        : view === 'inspector'
          ? html`<${CascadeInspector} />`
        : view === 'prometheus'
          ? html`<${PrometheusMetrics} />`
        : view === 'verification'
          ? html`<${VerificationSpecsPanel} />`
        : html`
            <${OasHealthChip} />
            <${CascadeConfigCanonicalLink} />
            <${HiddenDiagnosticsLinks} />
            <${CollapsibleSection} id="runtime-details-providers" title="런타임">
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

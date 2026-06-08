// RuntimePanel — Monitor "Runtime" lane.
// Renders OasHealthChip / RuntimeMonitor / VerificationSpecsPanel inline,
// and delegates telemetry views to
// TelemetryPanel (cost / audit).
//
// Progressive-disclosure default view (density reduction, 2026-04):
//   Signal layer     — RuntimeHealthSnapshot first, OasHealthChip below
//   Diagnostic layer — Runtime lanes via CollapsibleSection (closed)
//   Raw layer        — Formal specs via CollapsibleSection (closed)
// NN/g progressive disclosure: respect working-memory limits, defer detail.
//
// Explicit drill-down via FilterChips, split into two strips (PR #17014):
//   Primary strip   — default · providers · runtime.toml
//   Advanced strip  — cost · audit · verification
//                     (the first three are spread from TELEMETRY_VIEW_CHIPS,
//                      owned by telemetry-panel.ts; PR #17044 / #17052)
//
// Per-view dispatch:
//   default      — Signal strip + collapsed diagnostic/raw accordions
//   providers    — OAS health chip + runtime monitor only
//   config       — raw runtime.toml editor
//   cost / audit — TelemetryPanel → CostDashboard
//   verification — formal specs only
// Pattern: mirrors fleet-health-panel.ts (unidirectional flow via URL).

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { replaceRoute, route } from '../router'
import { FilterChips } from './common/filter-chips'
import { CollapsibleSection } from './common/collapsible'
import { OasHealthChip } from './oas-health-chip'
import { RuntimeHealthSnapshot } from './runtime-health-snapshot'
import { RuntimeMonitor } from './runtime-monitor'
import { RuntimeTomlEditor } from './runtime-toml-editor'
import { VerificationSpecsPanel } from './verification-specs-panel'
import { TelemetryPanel, isTelemetryView, TELEMETRY_VIEW_CHIPS } from './telemetry-panel'
import { RouteLink } from './common/route-link'

type RuntimeView =
  | 'default'
  | 'providers'
  | 'config'
  | 'cost'
  | 'audit'
  | 'verification'

const RUNTIME_VIEWS: RuntimeView[] = [
  'default',
  'providers',
  'config',
  'cost',
  'audit',
  'verification',
]

function isRuntimeView(v: string | undefined): v is RuntimeView {
  return !!v && (RUNTIME_VIEWS as string[]).includes(v)
}

const activeView = computed<RuntimeView>(() => {
  const v = route.value.params.view
  return isRuntimeView(v) ? v : 'default'
})

// Primary chips answer the keeper-facing question "can my tools run through
// which runtime, and why did the routing decision come out this way?"
// Default, providers (runtime health), and inspector (runtime decisions) are
// the views an operator opens during normal use.
const PRIMARY_VIEW_CHIPS: Array<{ key: RuntimeView; label: string }> = [
  { key: 'default', label: '전체' },
  { key: 'providers', label: '런타임' },
  { key: 'config', label: 'runtime.toml' },
]

// Advanced chips are infra/billing telemetry plus the raw / formal layers.
// The telemetry chips (cost / audit) are owned by
// telemetry-panel.ts — both their labels and their dispatch live there.
// Verification stays inline because runtime-panel still renders it directly.
const ADVANCED_VIEW_CHIPS: Array<{ key: RuntimeView; label: string }> = [
  ...TELEMETRY_VIEW_CHIPS,
  { key: 'verification', label: '형식검증' },
]

function updateViewParam(view: RuntimeView): void {
  replaceRoute(
    'monitoring',
    view === 'default'
      ? { section: 'runtime' }
      : { section: 'runtime', view },
  )
}

function HiddenDiagnosticsLinks() {
  const links = [
    {
      label: 'Transport diagnostics',
      detail: 'SSE/gRPC/WebSocket/WebRTC connection freshness.',
      section: 'transport-health',
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

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-2">
        <${FilterChips}
          chips=${PRIMARY_VIEW_CHIPS}
          value=${view}
          onChange=${updateViewParam}
          aria-label="Primary runtime views"
        />
        <div class="flex items-center gap-2 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          <span>고급 / 진단</span>
          <span class="h-px flex-1 bg-[var(--color-border-divider)]" aria-hidden="true"></span>
        </div>
        <${FilterChips}
          chips=${ADVANCED_VIEW_CHIPS}
          value=${view}
          onChange=${updateViewParam}
          aria-label="Advanced runtime views"
        />
      </div>
      <div class="grid gap-4">
        ${view === 'providers'
          ? html`
            <${RuntimeHealthSnapshot} />
            <${OasHealthChip} />
            <${RuntimeMonitor} />
          `
        : view === 'config'
          ? html`<${RuntimeTomlEditor} />`
        : isTelemetryView(view)
          ? html`<${TelemetryPanel} view=${view} />`
        : view === 'verification'
          ? html`<${VerificationSpecsPanel} />`
        : html`
            <${RuntimeHealthSnapshot} />
            <${OasHealthChip} />
            <${RuntimeMonitor} />
            <${HiddenDiagnosticsLinks} />
            <${CollapsibleSection} id="runtime-details-verification" title="형식검증">
              <${VerificationSpecsPanel} />
            <//>
          `}
      </div>
    </div>
  `
}

// MASC Dashboard — Status Surface (Phase 1: consolidated)
// Read-only observability surfaces: observatory, agents, activity, runtime,
// fleet-health (absorbs telemetry + fleet + tool-quality + governance), memory-subsystems.

import { html } from 'htm/preact'
import { route } from '../router'
import { AgentsUnified } from './agents-unified'
import { Activity } from './activity'
import { RuntimeMonitor } from './runtime-monitor'
import { OasHealthChip } from './oas-health-chip'
import { TelemetryUnified } from './telemetry-unified'
import { GovernanceMonitor } from './governance-monitor'
import { MemorySubsystems } from './memory-subsystems'
import { PrometheusMetrics } from './prometheus-metrics'
import { ToolQualityPanel } from './tool-quality-panel'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { Observatory } from './observatory/observatory'

type StatusSection = 'observatory' | 'agents' | 'activity' | 'runtime' | 'fleet-health' | 'memory-subsystems'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (
    section === 'observatory'
    || section === 'activity' || section === 'runtime'
    || section === 'fleet-health' || section === 'memory-subsystems'
  ) return section
  return 'agents'
}

// Phase 1 interim: routes fleet-health sub-views to existing panel components.
// Phase 2 replaces this with a unified FleetHealthPanel using FilterChips.
type FleetHealthView = 'event-log' | 'comparison' | 'tool-quality' | 'governance'

function currentFleetView(): FleetHealthView {
  const view = route.value.params.view
  if (view === 'comparison' || view === 'tool-quality' || view === 'governance') return view
  return 'event-log'
}

function FleetHealthRouter() {
  const view = currentFleetView()
  return html`
    ${view === 'event-log'
      ? html`<${TelemetryUnified} />`
    : view === 'comparison'
      ? html`<${FleetTelemetryPanel} />`
    : view === 'tool-quality'
      ? html`<${ToolQualityPanel} />`
    : html`<${GovernanceMonitor} />`}
  `
}

export function Status() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300">
        ${section === 'observatory'
          ? html`<${Observatory} />`
          : section === 'activity'
            ? html`<${Activity} />`
          : section === 'runtime'
            ? html`
              <div class="grid gap-4">
                <${OasHealthChip} />
                <${RuntimeMonitor} />
                <${PrometheusMetrics} />
              </div>
            `
          : section === 'fleet-health'
            ? html`<${FleetHealthRouter} />`
          : section === 'memory-subsystems'
            ? html`<${MemorySubsystems} />`
            : html`<${AgentsUnified} />`}
      </div>
    </div>
  `
}

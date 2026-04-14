// MASC Dashboard — Status Surface (Phase 2: fleet-health unified)
// Read-only observability surfaces: observatory, agents, activity, runtime,
// fleet-health (FilterChips unified panel), memory-subsystems.

import { html } from 'htm/preact'
import { route } from '../router'
import { AgentsUnified } from './agents-unified'
import { Activity } from './activity'
import { RuntimeMonitor } from './runtime-monitor'
import { OasHealthChip } from './oas-health-chip'
import { MemorySubsystems } from './memory-subsystems'
import { PrometheusMetrics } from './prometheus-metrics'
import { FleetHealthPanel } from './fleet-health-panel'
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
            ? html`<${FleetHealthPanel} />`
          : section === 'memory-subsystems'
            ? html`<${MemorySubsystems} />`
            : html`<${AgentsUnified} />`}
      </div>
    </div>
  `
}

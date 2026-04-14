// MASC Dashboard — Status Surface
// Read-only observability surfaces: agents, activity, runtime, telemetry, governance,
// memory-subsystems, fsm-hub, metrics, tool-quality, fleet.
// (sessions section removed in Phase 0 of RFC-MASC-006 — overlapped with overview.)

import { html } from 'htm/preact'
import { route } from '../router'
import { AgentsUnified } from './agents-unified'
import { Activity } from './activity'
import { RuntimeMonitor } from './runtime-monitor'
import { OasHealthChip } from './oas-health-chip'
import { TelemetryUnified } from './telemetry-unified'
import { GovernanceMonitor } from './governance-monitor'
import { MemorySubsystems } from './memory-subsystems'
import { FsmHub } from './fsm-hub'
import { PrometheusMetrics } from './prometheus-metrics'
import { ToolQualityPanel } from './tool-quality-panel'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { Observatory } from './observatory/observatory'

type StatusSection = 'observatory' | 'agents' | 'activity' | 'runtime' | 'telemetry' | 'governance' | 'memory-subsystems' | 'fsm-hub' | 'metrics' | 'tool-quality' | 'fleet'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (
    section === 'observatory'
    || section === 'activity' || section === 'runtime'
    || section === 'telemetry' || section === 'governance' || section === 'memory-subsystems'
    || section === 'fsm-hub' || section === 'metrics' || section === 'tool-quality' || section === 'fleet'
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
              </div>
            `
          : section === 'telemetry'
            ? html`<${TelemetryUnified} />`
          : section === 'governance'
            ? html`<${GovernanceMonitor} />`
          : section === 'memory-subsystems'
            ? html`<${MemorySubsystems} />`
          : section === 'fsm-hub'
            ? html`<${FsmHub} />`
          : section === 'metrics'
            ? html`<${PrometheusMetrics} />`
          : section === 'tool-quality'
            ? html`<${ToolQualityPanel} />`
          : section === 'fleet'
            ? html`<${FleetTelemetryPanel} />`
            : html`<${AgentsUnified} />`}
      </div>
    </div>
  `
}

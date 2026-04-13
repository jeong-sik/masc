// MASC Dashboard — Status Surface
// Conventional read-only status area: sessions, agents, activity, runtime, telemetry.

import { html } from 'htm/preact'
import { route } from '../router'
import { Mission } from './mission'
import { AgentsUnified } from './agents-unified'
import { Activity } from './activity'
import { RuntimeMonitor } from './runtime-monitor'
import { TelemetryUnified } from './telemetry-unified'
import { GovernanceMonitor } from './governance-monitor'
import { MemorySubsystems } from './memory-subsystems'

type StatusSection = 'sessions' | 'agents' | 'activity' | 'runtime' | 'telemetry' | 'governance' | 'memory-subsystems'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (section === 'agents' || section === 'activity' || section === 'runtime' || section === 'telemetry' || section === 'governance' || section === 'memory-subsystems') return section
  return 'sessions'
}

export function Status() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300">
        ${section === 'agents'
          ? html`<${AgentsUnified} />`
          : section === 'activity'
            ? html`<${Activity} />`
            : section === 'runtime'
              ? html`<${RuntimeMonitor} />`
            : section === 'telemetry'
              ? html`<${TelemetryUnified} />`
            : section === 'governance'
              ? html`<${GovernanceMonitor} />`
            : section === 'memory-subsystems'
              ? html`<${MemorySubsystems} />`
              : html`<${Mission} />`}
      </div>
    </div>
  `
}

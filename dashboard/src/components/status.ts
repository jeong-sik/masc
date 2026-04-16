// MASC Dashboard — Status Surface (Phase 2+4: fleet-health + runtime unified)
// Read-only observability surfaces: observatory, agents, activity, runtime,
// fleet-health (FilterChips unified panel), memory-subsystems.

import { html } from 'htm/preact'
import { route } from '../router'
import { AgentsUnified } from './agents-unified'
import { RuntimePanel } from './runtime-panel'
import { MemorySubsystems } from './memory-subsystems'
import { FleetHealthPanel } from './fleet-health-panel'
import { Observatory } from './observatory/observatory'

type StatusSection = 'observatory' | 'agents' | 'runtime' | 'fleet-health' | 'memory-subsystems'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (
    section === 'observatory'
    || section === 'runtime'
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
          : section === 'runtime'
            ? html`<${RuntimePanel} />`
          : section === 'fleet-health'
            ? html`<${FleetHealthPanel} />`
          : section === 'memory-subsystems'
            ? html`<${MemorySubsystems} />`
            : html`<${AgentsUnified} />`}
      </div>
    </div>
  `
}

// MASC Dashboard — Status Surface (Phase 2+4: fleet-health + runtime unified)
// Read-only observability surfaces: observatory, journey, agents, runtime,
// fleet-health (FilterChips unified panel), memory-subsystems.

import { html } from 'htm/preact'
import { route } from '../router'
import { AgentsUnified } from './agents-unified'
import { RuntimePanel } from './runtime-panel'
import { MemorySubsystems } from './memory-subsystems'
import { FleetHealthPanel } from './fleet-health-panel'
import { Observatory } from './observatory/observatory'
import { AttributionPanel } from './attribution-panel'
import { JourneyPanel } from './journey-panel'
import { SafeAutonomyPanel } from './safe-autonomy'

type StatusSection =
  | 'observatory' | 'journey' | 'agents' | 'runtime' | 'fleet-health'
  | 'safe-autonomy'
  | 'memory-subsystems' | 'attribution'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (
    section === 'observatory'
    || section === 'journey'
    || section === 'runtime'
    || section === 'fleet-health'
    || section === 'safe-autonomy'
    || section === 'memory-subsystems'
    || section === 'attribution'
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
          : section === 'journey'
            ? html`<${JourneyPanel} />`
          : section === 'runtime'
            ? html`<${RuntimePanel} />`
          : section === 'fleet-health'
            ? html`<${FleetHealthPanel} />`
          : section === 'safe-autonomy'
            ? html`<${SafeAutonomyPanel} />`
          : section === 'memory-subsystems'
            ? html`<${MemorySubsystems} />`
          : section === 'attribution'
            ? html`<${AttributionPanel} />`
            : html`<${AgentsUnified} />`}
      </div>
    </div>
  `
}

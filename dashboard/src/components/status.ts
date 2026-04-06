// MASC Dashboard — Status Surface
// Conventional read-only status area: sessions, agents, activity, telemetry.

import { html } from 'htm/preact'
import { route } from '../router'
import { Mission } from './mission'
import { AgentsUnified } from './agents-unified'
import { Activity } from './activity'
import { TelemetryUnified } from './telemetry-unified'

type StatusSection = 'sessions' | 'agents' | 'activity' | 'telemetry'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (section === 'agents' || section === 'activity' || section === 'telemetry') return section
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
            : section === 'telemetry'
              ? html`<${TelemetryUnified} />`
              : html`<${Mission} />`}
      </div>
    </div>
  `
}

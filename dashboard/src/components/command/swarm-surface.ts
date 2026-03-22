import { html } from 'htm/preact'
import { SwarmLivePanels } from './swarm-live-panels'
import { SwarmOverviewPanel } from './swarm-overview-panel'

export function SwarmSurface() {
  return html`
    <div class="flex flex-col gap-4">
      <${SwarmOverviewPanel} />
      <${SwarmLivePanels} />
    </div>
  `
}

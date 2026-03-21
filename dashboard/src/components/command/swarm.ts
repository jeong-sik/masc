import { html } from 'htm/preact'
import { SwarmOverviewPanel } from './swarm-overview-panel'
import { SwarmLivePanels } from './swarm-live-panels'

// Re-export for consumers that import from './swarm'
export { SwarmBlockerCard, SwarmChecklistCard, SwarmWorkerCard } from './swarm-cards'
export { SwarmHealthBar, SwarmRunResolutionCard, SwarmStoryboard } from './swarm-storyboard'

export function SwarmSurface() {
  return html`
    <div class="command-section-stack">
      <${SwarmOverviewPanel} />
      <${SwarmLivePanels} />
    </div>
  `
}

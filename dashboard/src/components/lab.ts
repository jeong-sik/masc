import { html } from 'htm/preact'
import { route } from '../router'
import { Tools } from './tools/tools-main'
import { HarnessHealth } from './harness-health'
import { DesignCanvas } from './design-canvas'
import { LabPerf } from './lab-perf'
import { MemoryExplore } from './memory/memory-explore'
import { KeeperMemoryHealth } from './memory/keeper-memory-health'
import { SurfaceHeader } from './common/surface-header'

type LabSection = 'tools' | 'harness' | 'design-canvas' | 'performance' | 'memory-explore' | 'keeper-memory-health'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (
    section === 'harness'
    || section === 'design-canvas'
    || section === 'performance'
    || section === 'memory-explore'
    || section === 'keeper-memory-health'
  ) {
    return section
  }
  return 'tools'
}

export function Lab() {
  const section = currentSection()

  return html`
    <div class="v2-lab-surface ss-surface bg-surface-page flex flex-col gap-6" data-testid="lab-surface">
      <${SurfaceHeader} />
      ${section === 'tools' ? html`
        <${Tools} />
      ` : null}

      ${section === 'harness' ? html`
        <${HarnessHealth} />
      ` : null}

      ${section === 'design-canvas' ? html`
        <${DesignCanvas} />
      ` : null}

      ${section === 'performance' ? html`
        <${LabPerf} />
      ` : null}

      ${section === 'memory-explore' ? html`
        <${MemoryExplore} />
      ` : null}

      ${section === 'keeper-memory-health' ? html`
        <${KeeperMemoryHealth} />
      ` : null}
    </div>
  `
}

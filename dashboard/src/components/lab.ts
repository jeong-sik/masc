import { html } from 'htm/preact'
import { route } from '../router'
import { Tools } from './tools/tools-main'
import { HarnessHealth } from './harness-health'
import { DesignCanvas } from './design-canvas'
import { LabPerf } from './lab-perf'
import { MemoryExplore } from './memory/memory-explore'

type LabSection = 'tools' | 'harness' | 'design-canvas' | 'performance' | 'memory-explore'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (
    section === 'harness'
    || section === 'design-canvas'
    || section === 'performance'
    || section === 'memory-explore'
  ) {
    return section
  }
  return 'tools'
}

export function Lab() {
  const section = currentSection()

  return html`
    <div class="v2-lab-surface flex flex-col gap-6" data-testid="lab-surface">
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
    </div>
  `
}

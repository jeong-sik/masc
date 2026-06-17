import { html } from 'htm/preact'
import { route } from '../router'
import { Tools } from './tools/tools-main'
import { HarnessHealth } from './harness-health'
import { DesignCanvas } from './design-canvas'

type LabSection = 'tools' | 'harness' | 'design-canvas'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (section === 'harness' || section === 'design-canvas') {
    return section
  }
  return 'tools'
}

export function Lab() {
  const section = currentSection()

  return html`
    <div class="v2-lab-surface flex flex-col gap-6">
      ${section === 'tools' ? html`
        <${Tools} />
      ` : null}

      ${section === 'harness' ? html`
        <${HarnessHealth} />
      ` : null}

      ${section === 'design-canvas' ? html`
        <${DesignCanvas} />
      ` : null}
    </div>
  `
}

import { html } from 'htm/preact'
import { route } from '../router'
import { Card } from './common/card'
import { Tools } from './tools'
import { Autoresearch } from './autoresearch'
import { HarnessHealth } from './harness-health'

type LabSection = 'tools' | 'autoresearch' | 'harness'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (section === 'autoresearch' || section === 'harness') {
    return section
  }
  return 'tools'
}

export function Lab() {
  const section = currentSection()

  return html`
    <div>
      ${section === 'tools' ? html`
        <${Tools} />
      ` : null}

      ${section === 'autoresearch' ? html`
        <${Card} title="오토리서치" class="section mb-4">
          <${Autoresearch} />
        <//>
      ` : null}

      ${section === 'harness' ? html`
        <${HarnessHealth} />
      ` : null}
    </div>
  `
}

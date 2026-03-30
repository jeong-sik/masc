import { html } from 'htm/preact'
import { route } from '../router'
import { Card } from './common/card'
import { Tools } from './tools'
import { Autoresearch } from './autoresearch'
import { HarnessHealth } from './harness-health'
import { FeatureHealth } from './feature-health'
import { ServerConfig } from './server-config'

type LabSection = 'tools' | 'autoresearch' | 'harness' | 'features' | 'config'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (section === 'autoresearch' || section === 'harness' || section === 'features' || section === 'config') {
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

      ${section === 'features' ? html`
        <${FeatureHealth} />
      ` : null}

      ${section === 'config' ? html`
        <${ServerConfig} />
      ` : null}
    </div>
  `
}

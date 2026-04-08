import { html } from 'htm/preact'
import { route } from '../router'
import { Card } from './common/card'
import { Tools } from './tools'
import { Autoresearch } from './autoresearch'
import { HarnessHealth } from './harness-health'
import { LabInspector } from './lab-inspector'
import { ToolQualityPanel } from './tool-quality-panel'

type LabSection = 'tools' | 'autoresearch' | 'harness' | 'inspector' | 'tool-quality'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (section === 'autoresearch' || section === 'harness' || section === 'inspector' || section === 'tool-quality') {
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

      ${section === 'inspector' ? html`
        <${LabInspector} />
      ` : null}

      ${section === 'tool-quality' ? html`
        <${Card} title="도구 품질" class="section mb-4">
          <${ToolQualityPanel} />
        <//>
      ` : null}
    </div>
  `
}

import { html } from 'htm/preact'
import { route } from '../router'
import { Card } from './common/card'
import { Tools } from './tools'
import { Autoresearch } from './autoresearch'
import { HarnessHealth } from './harness-health'

export function Lab() {
  const section = route.value.params.section ?? 'tools'

  return html`
    <div>
      ${section === 'tools' ? html`
        <${Tools} mode="tools" />
      ` : null}

      ${section === 'experiments' ? html`
        <${Tools} mode="experiments" />
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

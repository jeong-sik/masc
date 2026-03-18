// MASC Dashboard — Control Tab
// Absorbs: intervene + tools. Ops (intervene) default, tools as secondary.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Ops } from './ops'
import { Tools } from './tools'

type ControlSection = 'intervene' | 'tools'

export function Control() {
  const section: ControlSection = route.value.params.section === 'tools' ? 'tools' : 'intervene'

  return html`
    <div class="tab-unified">
      <div class="tab-pill-bar">
        <button
          class="tab-pill ${section === 'intervene' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('control')}
        >
          개입
        </button>
        <button
          class="tab-pill ${section === 'tools' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('control', { section: 'tools' })}
        >
          도구
        </button>
      </div>

      ${section === 'tools'
        ? html`<${Tools} />`
        : html`<${Ops} />`
      }
    </div>
  `
}

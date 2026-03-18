// MASC Dashboard — Work Tab
// Absorbs: memory(board) + governance + proof + planning into pill-switched sections.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Memory } from './memory'
import { Governance } from './governance'
import { Proof } from './proof'
import { Planning } from './goals'

type WorkSection = 'board' | 'governance' | 'evidence' | 'planning'

const SECTIONS: { id: WorkSection; label: string }[] = [
  { id: 'board', label: '\uAC8C\uC2DC\uD310' },
  { id: 'governance', label: '\uAC70\uBC84\uB10C\uC2A4' },
  { id: 'evidence', label: '\uADFC\uAC70' },
  { id: 'planning', label: '\uACC4\uD68D' },
]

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'governance' || v === 'evidence' || v === 'planning'
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'board'

  return html`
    <div class="tab-unified">
      <div class="tab-pill-bar">
        ${SECTIONS.map(s => html`
          <button
            key=${s.id}
            class="tab-pill ${current === s.id ? 'tab-pill--active' : ''}"
            onClick=${() => navigate('work', { section: s.id })}
          >
            ${s.label}
          </button>
        `)}
      </div>

      ${current === 'board' ? html`<${Memory} />`
        : current === 'governance' ? html`<${Governance} />`
        : current === 'evidence' ? html`<${Proof} />`
        : html`<${Planning} />`
      }
    </div>
  `
}

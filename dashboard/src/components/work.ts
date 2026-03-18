// MASC Dashboard — Work Tab
// Absorbs: memory(board) + governance + proof + planning into pill-switched sections.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Memory } from './memory'
import { Governance } from './governance'
import { Proof } from './proof'
import { Planning } from './goals'

type WorkSection = 'board' | 'governance' | 'evidence' | 'planning'

const SECTIONS: { id: WorkSection; label: string; tooltip: string }[] = [
  { id: 'board', label: '\uAC8C\uC2DC\uD310', tooltip: '\uC5D0\uC774\uC804\uD2B8 \uAC04 \uC18C\uD1B5\uACFC \uC9C0\uC2DD \uACF5\uC720' },
  { id: 'governance', label: '\uAC70\uBC84\uB10C\uC2A4', tooltip: '\uC758\uC0AC\uACB0\uC815 \uAE30\uB85D\uACFC \uD310\uACB0' },
  { id: 'evidence', label: '\uADFC\uAC70', tooltip: '\uC791\uC5C5 \uC99D\uAC70\uC640 \uAC80\uC99D \uACB0\uACFC' },
  { id: 'planning', label: '\uACC4\uD68D', tooltip: '\uC7A5\uAE30 \uBAA9\uD45C\uC640 \uBA54\uD2B8\uB9AD \uB8E8\uD504' },
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
            title=${s.tooltip}
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

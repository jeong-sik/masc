// MASC Dashboard — Operations Surface
// Operator dashboard split: intervene + governance.

import { html } from 'htm/preact'
import { route } from '../router'
import { Ops } from './ops'
import { Governance } from './governance'

type OperationsSection = 'intervene' | 'governance'

function currentSection(): OperationsSection {
  const section = route.value.params.section
  if (section === 'governance') return section
  return 'intervene'
}

export function Operations() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300">
        ${section === 'governance'
          ? html`<${Governance} />`
          : html`<${Ops} />`}
      </div>
    </div>
  `
}

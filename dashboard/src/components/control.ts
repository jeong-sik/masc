// MASC Dashboard — Operations Surface
// Conventional operator dashboard split: intervene + command + tools.

import { html } from 'htm/preact'
import { route } from '../router'
import { Ops } from './ops'
import { Command } from './command'
import { Governance } from './governance'

type OperationsSection = 'intervene' | 'warroom' | 'governance'

function currentSection(): OperationsSection {
  const section = route.value.params.section
  if (section === 'warroom' || section === 'governance') return section
  return 'intervene'
}

export function Operations() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-4">
      <div class="transition-opacity duration-300">
        ${section === 'governance'
          ? html`<${Governance} />`
          : section === 'warroom'
            ? html`<${Command} />`
            : html`<${Ops} />`}
      </div>
    </div>
  `
}

export const Control = Operations

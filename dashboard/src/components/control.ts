// MASC Dashboard — Operations Surface
// Operator dashboard split: intervene + governance + connectors.

import { html } from 'htm/preact'
import { route } from '../router'
import { Ops } from './ops'
import { Governance } from './governance'
import { ConnectorStatusPanel } from './connector-status'

type OperationsSection = 'intervene' | 'governance' | 'connectors'

function currentSection(): OperationsSection {
  const section = route.value.params.section
  if (section === 'governance') return section
  if (section === 'connectors') return section
  return 'intervene'
}

function renderSection(section: OperationsSection) {
  switch (section) {
    case 'governance':
      return html`<${Governance} />`
    case 'connectors':
      return html`<${ConnectorStatusPanel} />`
    case 'intervene':
      return html`<${Ops} />`
  }
}

export function Operations() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300">
        ${renderSection(section)}
      </div>
    </div>
  `
}

// MASC Dashboard — Operations Surface
// Operator dashboard split: intervene + governance + connectors + inspector.

import { html } from 'htm/preact'
import { route } from '../router'
import { Ops } from './ops'
import { Governance } from './governance'
import { ConnectorStatusPanel } from './connector-status'
import { LabInspector } from './lab-inspector'

type OperationsSection = 'intervene' | 'governance' | 'connectors' | 'inspector'

function currentSection(): OperationsSection {
  const section = route.value.params.section
  if (section === 'governance') return section
  if (section === 'connectors') return section
  if (section === 'inspector') return section
  return 'intervene'
}

function renderSection(section: OperationsSection) {
  switch (section) {
    case 'governance':
      return html`<${Governance} />`
    case 'connectors':
      return html`<${ConnectorStatusPanel} />`
    case 'inspector':
      return html`<${LabInspector} />`
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

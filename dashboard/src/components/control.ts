// MASC Dashboard — Operations Surface (Phase 1: consolidated)
// operations (absorbs intervene + governance) + connectors + inspector.

import { html } from 'htm/preact'
import { route } from '../router'
import { OperationsPanel } from './operations-panel'
import { ConnectorStatusPanel } from './connector-status'
import { LabInspector } from './lab-inspector'

type OperationsSection = 'operations' | 'connectors' | 'inspector'

function currentSection(): OperationsSection {
  const section = route.value.params.section
  if (section === 'connectors') return section
  if (section === 'inspector') return section
  return 'operations'
}

function renderSection(section: OperationsSection) {
  switch (section) {
    case 'connectors':
      return html`<${ConnectorStatusPanel} />`
    case 'inspector':
      return html`<${LabInspector} />`
    case 'operations':
      return html`<${OperationsPanel} />`
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

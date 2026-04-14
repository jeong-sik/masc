// MASC Dashboard — Operations Surface (Phase 1: consolidated)
// operations (absorbs intervene + governance) + connectors + inspector.

import { html } from 'htm/preact'
import { route } from '../router'
import { Ops } from './ops'
import { Governance } from './governance'
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
      // Phase 1 interim: render Ops (intervention) and Governance (approval
      // queue) vertically. Phase 5 merges them into a unified operations-panel
      // with broadcast/message/approve sections.
      return html`
        <${Ops} />
        <div class="mt-4">
          <${Governance} />
        </div>
      `
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

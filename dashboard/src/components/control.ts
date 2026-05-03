// MASC Dashboard — Operations Surface (Phase 6: fully unified)
// All command sub-views (ops, governance, connectors, inspector) are now
// FilterChips views inside OperationsPanel.

import { html } from 'htm/preact'
import { OperationsPanel } from './operations-panel'

export function Operations() {
  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-[var(--t-slow)]">
        <${OperationsPanel} />
      </div>
    </div>
  `
}

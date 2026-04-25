// MASC Dashboard — Work Tab (Phase 7: planning with goal-tree sub-view)
// board + planning + verification.

import { html } from 'htm/preact'
import { route } from '../router'
import { Memory } from './memory'
import { PlanningPanel } from './planning-panel'
import { VerificationRequestsPanel } from './verification-requests-panel'
import { ErrorBoundary } from './common/error-boundary'

type WorkSection = 'board' | 'planning' | 'verification'

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'planning' || v === 'verification'
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'board'

  return html`
    <div class="flex flex-col gap-5" role="region" aria-label="작업">
      <div class="transition-opacity duration-300">
        <${ErrorBoundary} label=${current}>
          ${current === 'board' ? html`<${Memory} />`
            : current === 'planning' ? html`<${PlanningPanel} />`
            : html`<${VerificationRequestsPanel} />`
          }
        </>
      </div>
    </div>
  `
}

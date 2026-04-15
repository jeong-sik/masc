// MASC Dashboard — Work Tab (Phase 7: planning with goal-tree sub-view)
// board + planning (FilterChips: kanban / goal-tree).

import { html } from 'htm/preact'
import { route } from '../router'
import { Memory } from './memory'
import { PlanningPanel } from './planning-panel'
import { ErrorBoundary } from './common/error-boundary'

type WorkSection = 'board' | 'planning'

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'planning'
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'board'

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300">
        <${ErrorBoundary} label=${current}>
          ${current === 'board' ? html`<${Memory} />`
            : html`<${PlanningPanel} />`
          }
        </>
      </div>
    </div>
  `
}

// MASC Dashboard — Work Tab
// Absorbs: memory(board) + planning + goals into pill-switched sections.

import { html } from 'htm/preact'
import { route } from '../router'
import { Memory } from './memory'
import { Planning } from './goals'
import { GoalTree } from './goals/goal-tree'
import { ErrorBoundary } from './common/error-boundary'

type WorkSection = 'board' | 'planning' | 'goals'

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'planning' || v === 'goals'
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
            : current === 'planning' ? html`<${Planning} />`
            : html`<${GoalTree} />`
          }
        </>
      </div>
    </div>
  `
}

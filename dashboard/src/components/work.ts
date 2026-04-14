// MASC Dashboard — Work Tab (Phase 1: goals absorbed into planning)
// board + planning (includes goal pipeline summary + goals deep-link).

import { html } from 'htm/preact'
import { route } from '../router'
import { Memory } from './memory'
import { Planning } from './goals'
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
            : html`<${Planning} />`
          }
        </>
      </div>
    </div>
  `
}

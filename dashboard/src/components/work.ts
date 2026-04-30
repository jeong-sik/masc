// MASC Dashboard — Work Tab (Phase 7: planning with goal-tree sub-view)
// board + planning + verification.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { Memory } from './memory'
import { PlanningPanel } from './planning-panel'
import { VerificationRequestsPanel } from './verification-requests-panel'
import { ErrorBoundary } from './common/error-boundary'
import { LoadingState } from './common/feedback-state'

type WorkSection = 'board' | 'planning' | 'collab-mvp' | 'verification'

const LazyCollabMvp = lazy(async () => ({
  default: (await import('./collab-mvp')).CollabMvp,
}))

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'planning' || v === 'collab-mvp' || v === 'verification'
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
            : current === 'planning' ? html`<${PlanningPanel} />`
            : current === 'collab-mvp' ? html`
              <${Suspense} fallback=${html`<${LoadingState}>협업 화면 불러오는 중...<//>`}>
                <${LazyCollabMvp} />
              <//>
            `
            : html`<${VerificationRequestsPanel} />`
          }
        </>
      </div>
    </div>
  `
}

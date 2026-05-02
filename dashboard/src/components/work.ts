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

type WorkSection = 'board' | 'planning' | 'repositories' | 'verification'

const LazyRepositoryManagement = lazy(async () => ({
  default: (await import('./repository-management')).RepositoryManagement,
}))

export function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'planning' || v === 'repositories' || v === 'verification'
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'board'

  return html`
    <div class="flex min-w-0 flex-col gap-3">
      <div class="min-w-0 transition-opacity duration-[var(--t-slow)]">
        <${ErrorBoundary} label=${current}>
          ${current === 'board' ? html`<${Memory} />`
            : current === 'planning' ? html`<${PlanningPanel} />`
            : current === 'repositories' ? html`
              <${Suspense} fallback=${html`<${LoadingState}>저장소 화면 불러오는 중...<//>`}>
                <${LazyRepositoryManagement} />
              <//>
            `
            : html`<${VerificationRequestsPanel} />`
          }
        </>
      </div>
    </div>
  `
}

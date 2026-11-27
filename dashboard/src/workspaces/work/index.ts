/**
 * `2 Work` Workspace Entry (`dashboard/src/workspaces/work/index.ts`)
 *
 * L1 subroutes: `goals | tasks | inbox | candle`.
 */

import { html } from 'htm/preact'
import { Suspense } from 'preact/compat'
import './work.css'
import { sessionEpoch } from '../../core/auth'
import { createPreloadableLazy } from '../../lib/lazy-component'
import { registerSubroutePreloader } from '../registry'
import { GoalsTab } from './goals-tab'
import {
  normalizeWorkSubroute,
  type WorkSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
} from './types'

const tasksTab = createPreloadableLazy<WorkspaceViewProps>(async () => (await import('./tasks-tab')).TasksTab)
const inboxTab = createPreloadableLazy<WorkspaceViewProps>(async () => (await import('./inbox-tab')).InboxTab)
const candleTab = createPreloadableLazy<WorkspaceViewProps>(async () => (await import('./candle-tab')).CandleTab)

export function preloadWorkSubroute(subroute: WorkSubroute | string): Promise<void> {
  switch (normalizeWorkSubroute(subroute)) {
    case 'tasks':
      return tasksTab.preload()
    case 'inbox':
      return inboxTab.preload()
    case 'candle':
      return candleTab.preload()
    default:
      return Promise.resolve()
  }
}

registerSubroutePreloader('work', (subroute) => {
  void preloadWorkSubroute(subroute).catch(() => {})
})

export type { WorkspaceInspectPayload, WorkspaceViewProps, WorkSubroute }
export * from './types'
export { GoalsTab }

export function WorkWorkspace(props: WorkspaceViewProps) {
  const activeTab = normalizeWorkSubroute(props.subroute)

  return html`
    <section class="wk-root" aria-label="Work workspace">
      <div class="wk-body">
        ${activeTab === 'goals' && html`<${GoalsTab} key=${sessionEpoch.value} ...${props} />`}
        ${activeTab !== 'goals' && html`
          <${Suspense} fallback=${null}>
            ${activeTab === 'tasks' && html`<${tasksTab.Component} ...${props} />`}
            ${activeTab === 'inbox' && html`<${inboxTab.Component} ...${props} />`}
            ${activeTab === 'candle' && html`<${candleTab.Component} ...${props} />`}
          <//>
        `}
      </div>
    </section>
  `
}

/**
 * `2 Work` Workspace Entry (`dashboard/src/workspaces/work/index.ts`)
 *
 * L1 subroutes: `goals | tasks | inbox | candle`.
 */

import { html } from 'htm/preact'
import './work.css'
import { GoalsTab } from './goals-tab'
import { TasksTab } from './tasks-tab'
import { InboxTab } from './inbox-tab'
import { CandleTab } from './candle-tab'
import {
  normalizeWorkSubroute,
  type WorkSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
} from './types'

export type { WorkspaceInspectPayload, WorkspaceViewProps, WorkSubroute }
export * from './types'
export { GoalsTab, TasksTab, InboxTab, CandleTab }

const WORK_TABS: readonly { id: WorkSubroute; label: string }[] = [
  { id: 'goals', label: 'Goals' },
  { id: 'tasks', label: 'Tasks & Schedules' },
  { id: 'inbox', label: 'Unified Inbox' },
  { id: 'candle', label: 'Candle & Scorecard' },
]

export function WorkWorkspace(props: WorkspaceViewProps) {
  const activeTab = normalizeWorkSubroute(props.subroute)

  return html`
    <section class="wk-root" aria-label="Work workspace">
      <header class="wk-subbar">
        <div class="wk-tabs" role="tablist" aria-label="Work sub-tabs">
          ${WORK_TABS.map((tab) => html`
            <button
              key=${tab.id}
              type="button"
              role="tab"
              class="wk-tab"
              aria-selected=${activeTab === tab.id}
              onClick=${() => props.onNavigate(`/work/${tab.id}`)}
            >
              ${tab.label}
            </button>
          `)}
        </div>
      </header>

      <div class="wk-body">
        ${activeTab === 'goals' && html`<${GoalsTab} ...${props} />`}
        ${activeTab === 'tasks' && html`<${TasksTab} ...${props} />`}
        ${activeTab === 'inbox' && html`<${InboxTab} ...${props} />`}
        ${activeTab === 'candle' && html`<${CandleTab} ...${props} />`}
      </div>
    </section>
  `
}

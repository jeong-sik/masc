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

export function WorkWorkspace(props: WorkspaceViewProps) {
  const activeTab = normalizeWorkSubroute(props.subroute)

  return html`
    <section class="wk-root" aria-label="Work workspace">
      <div class="wk-body">
        ${activeTab === 'goals' && html`<${GoalsTab} ...${props} />`}
        ${activeTab === 'tasks' && html`<${TasksTab} ...${props} />`}
        ${activeTab === 'inbox' && html`<${InboxTab} ...${props} />`}
        ${activeTab === 'candle' && html`<${CandleTab} ...${props} />`}
      </div>
    </section>
  `
}

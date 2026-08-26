// MASC Dashboard — Operations Panel (Phase 5+6+7)
// FilterChips toggle for ops/Gate/inspector sub-views.

import { html } from 'htm/preact'
import { FilterChips } from './common/filter-chips'
import { SurfaceHeader } from './common/surface-header'
import { Ops } from './ops'
import { ApprovalsSurface } from './approvals/approvals-surface'
import { KeeperAsksSurface } from './keeper-asks/keeper-asks-surface'
import { LabInspector } from './lab-inspector'
import { replaceRoute, route } from '../router'

type OpsView = 'default' | 'ops' | 'gate' | 'asks' | 'inspector'

const VALID_VIEWS: OpsView[] = ['default', 'ops', 'gate', 'asks', 'inspector']

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: 'All' },
  { key: 'ops', label: 'Intervene' },
  { key: 'gate', label: 'Gate / HITL' },
  // Its own chip rather than a section of Gate: nothing is held waiting on a
  // question, so it is not part of the approval queue's backlog.
  { key: 'asks', label: '질문' },
  { key: 'inspector', label: 'Inspector' },
]

function currentView(): OpsView {
  const view = route.value.params.view
  if (view && (VALID_VIEWS as string[]).includes(view)) return view as OpsView
  return 'default'
}

function updateViewParam(next: OpsView): void {
  replaceRoute(
    'command',
    next === 'default'
      ? { section: 'operations' }
      : { section: 'operations', view: next },
  )
}

export function OperationsPanel() {
  const view = currentView()

  return html`
    <div class="v2-command-surface flex flex-col gap-4">
      <${SurfaceHeader} />
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="md"
        tone="accent"
        class="w-fit"
      />
      ${view === 'ops'
        ? html`<${Ops} />`
      : view === 'gate'
        ? html`<${ApprovalsSurface} />`
      : view === 'asks'
        ? html`<${KeeperAsksSurface} />`
      : view === 'inspector'
        ? html`<${LabInspector} />`
      : html`
            <${Ops} />
            <div class="mt-4">
              <${KeeperAsksSurface} />
            </div>
            <div class="mt-4">
              <${ApprovalsSurface} />
            </div>
          `}
    </div>
  `
}

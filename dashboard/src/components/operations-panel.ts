// MASC Dashboard — interventions, keeper questions and server configuration.

import { html } from 'htm/preact'
import { FilterChips } from './common/filter-chips'
import { SurfaceHeader } from './common/surface-header'
import { Ops } from './ops'
import { KeeperAsksSurface } from './keeper-asks/keeper-asks-surface'
import { ServerConfig } from './server-config'
import { replaceRoute, route } from '../router'

type OpsView = 'default' | 'ops' | 'asks' | 'inspector'

const VALID_VIEWS: OpsView[] = ['default', 'ops', 'asks', 'inspector']

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: 'All' },
  { key: 'ops', label: 'Intervene' },
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
      : view === 'asks'
        ? html`<${KeeperAsksSurface} />`
      : view === 'inspector'
        ? html`<${ServerConfig} />`
      : html`
            <${Ops} />
            <div class="mt-4">
              <${KeeperAsksSurface} />
            </div>
          `}
    </div>
  `
}

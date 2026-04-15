// MASC Dashboard — Operations Panel (Phase 5+6)
// FilterChips toggle for ops/governance/connectors/inspector sub-views.
// Phase 6: connectors and inspector absorbed as sub-views.

import { html } from 'htm/preact'
import { FilterChips } from './common/filter-chips'
import { Ops } from './ops'
import { Governance } from './governance'
import { ConnectorStatusPanel } from './connector-status'
import { LabInspector } from './lab-inspector'
import { route } from '../router'

export type OpsView = 'default' | 'ops' | 'governance' | 'connectors' | 'inspector'

const VALID_VIEWS: OpsView[] = ['default', 'ops', 'governance', 'connectors', 'inspector']

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: '전체' },
  { key: 'ops', label: '개입' },
  { key: 'governance', label: '거버넌스' },
  { key: 'connectors', label: '커넥터' },
  { key: 'inspector', label: '인스펙터' },
]

function currentView(): OpsView {
  const view = route.value.params.view
  if (view && (VALID_VIEWS as string[]).includes(view)) return view as OpsView
  return 'default'
}

function updateViewParam(next: OpsView): void {
  const base = '#command?section=operations'
  const hash = next === 'default' ? base : `${base}&view=${next}`
  window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}${hash}`)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

export function OperationsPanel() {
  const view = currentView()

  return html`
    <div class="flex flex-col gap-4">
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
      : view === 'governance'
        ? html`<${Governance} />`
      : view === 'connectors'
        ? html`<${ConnectorStatusPanel} />`
      : view === 'inspector'
        ? html`<${LabInspector} />`
      : html`
            <${Ops} />
            <div class="mt-4">
              <${Governance} />
            </div>
          `}
    </div>
  `
}

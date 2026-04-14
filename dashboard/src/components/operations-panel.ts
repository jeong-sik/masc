// MASC Dashboard — Operations Panel (Phase 5)
// FilterChips toggle for ops/governance sub-views within the operations section.

import { html } from 'htm/preact'
import { FilterChips } from './common/filter-chips'
import { Ops } from './ops'
import { Governance } from './governance'
import { route } from '../router'

export type OpsView = 'default' | 'ops' | 'governance'

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: '전체' },
  { key: 'ops', label: '개입' },
  { key: 'governance', label: '거버넌스' },
]

function currentView(): OpsView {
  const view = route.value.params.view
  if (view === 'ops' || view === 'governance') return view
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
          : html`
              <${Ops} />
              <div class="mt-4">
                <${Governance} />
              </div>
            `}
    </div>
  `
}

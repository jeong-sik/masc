// MASC Dashboard — Operations Panel (Phase 5+6+7)
// FilterChips toggle for ops/governance/inspector sub-views.
// Phase 7: connectors split out as a top-level surface (#command?view=connectors → #connectors).

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { FilterChips } from './common/filter-chips'
import { Ops } from './ops'
import { Governance } from './governance'
import { LabInspector } from './lab-inspector'
import { route } from '../router'

type OpsView = 'default' | 'ops' | 'governance' | 'inspector'

const VALID_VIEWS: OpsView[] = ['default', 'ops', 'governance', 'inspector']

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: '전체' },
  { key: 'ops', label: '개입' },
  { key: 'governance', label: '거버넌스' },
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

// Legacy URL migration (Phase 7):
// #command?section=operations&view=connectors → #connectors?section=connector-status
function redirectLegacyConnectorsView(): void {
  const hash = '#connectors?section=connector-status'
  window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}${hash}`)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

export function OperationsPanel() {
  const rawView = route.value.params.view
  const isLegacyConnectors = rawView === 'connectors'

  useEffect(() => {
    if (isLegacyConnectors) redirectLegacyConnectorsView()
  }, [isLegacyConnectors])

  if (isLegacyConnectors) return null

  const view = currentView()

  return html`
    <div class="flex flex-col gap-4" role="region" aria-label="운영 패널">
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

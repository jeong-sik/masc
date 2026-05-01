// MASC Dashboard — Operations Panel (Phase 5+6+7)
// FilterChips toggle for ops/governance/safety/inspector sub-views.
// Phase 7: connectors split out as a top-level surface (#command?view=connectors → #connectors).

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { FilterChips } from './common/filter-chips'
import { Ops } from './ops'
import { Governance } from './governance'
import { LabInspector } from './lab-inspector'
import { SafeAutonomyPanel } from './safe-autonomy'
import { replaceRoute, route } from '../router'

type OpsView = 'default' | 'ops' | 'governance' | 'safety' | 'inspector'

const VALID_VIEWS: OpsView[] = ['default', 'ops', 'governance', 'safety', 'inspector']

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: 'All' },
  { key: 'ops', label: 'Intervene' },
  { key: 'governance', label: 'Governance' },
  { key: 'safety', label: 'Safety' },
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

// Legacy URL migration (Phase 7):
// #command?section=operations&view=connectors → #connectors?section=connector-status
function redirectLegacyConnectorsView(): void {
  replaceRoute('connectors', { section: 'connector-status' })
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
      : view === 'safety'
        ? html`<${SafeAutonomyPanel} />`
      : view === 'inspector'
        ? html`<${LabInspector} />`
      : html`
            <${Ops} />
            <div class="mt-4">
              <${Governance} />
            </div>
            <div class="mt-4">
              <${SafeAutonomyPanel} />
            </div>
          `}
    </div>
  `
}

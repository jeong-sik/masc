// MASC Dashboard — Operations Panel (Phase 5+6+7)
// FilterChips toggle for ops/governance/safety/inspector sub-views.
// Phase 7: connectors split out as a top-level surface. Legacy
// command:connectors links are routed before this panel mounts.

import { html } from 'htm/preact'
import { FilterChips } from './common/filter-chips'
import { Ops } from './ops'
import { Governance } from './governance'
import { LabInspector } from './lab-inspector'
import { SurfaceReadinessPanel } from './surface-readiness-panel'
import { replaceRoute, route } from '../router'

type OpsView = 'default' | 'ops' | 'governance' | 'surfaces' | 'inspector'

const VALID_VIEWS: OpsView[] = ['default', 'ops', 'governance', 'surfaces', 'inspector']

const VIEW_CHIPS: { key: OpsView; label: string }[] = [
  { key: 'default', label: 'All' },
  { key: 'ops', label: 'Intervene' },
  { key: 'governance', label: 'Governance' },
  { key: 'surfaces', label: 'Surfaces' },
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
      : view === 'surfaces'
        ? html`<${SurfaceReadinessPanel} />`
      : view === 'inspector'
        ? html`<${LabInspector} />`
      : html`
            <${Ops} />
            <div class="mt-4">
              <${Governance} />
            </div>
            <div class="mt-4">
              <${SurfaceReadinessPanel} />
            </div>
          `}
    </div>
  `
}

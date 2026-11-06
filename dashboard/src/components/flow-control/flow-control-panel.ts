import { html } from 'htm/preact'
import { requestConfirm } from '../common/confirm-dialog'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { shellAuthSummary } from '../../store'
import { operatorSnapshot } from '../../operator-store'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import {
  maintenanceResult, maintenanceLoading, runGarbageCollection,
} from './flow-control-state'

export function FlowControlPanel() {
  const maintenanceAccess = dashboardAuthAccess(shellAuthSummary.value, 'admin')
  const inferenceInflight = operatorSnapshot.value?.inference_inflight ?? null
  return html`
    <div class="v2-command-surface flex flex-col gap-4">
    ${inferenceInflight ? html`
      <${SurfaceCard} variant="compact" class="v2-command-panel">
        <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-testid="flow-inference-inflight">
          <span>Boundary owner: ${inferenceInflight.boundary_owner}</span>
          <span>${inferenceInflight.active} active inference</span>
        </div>
      <//>
    ` : null}

    ${'' /* ── Maintenance ── */}
    <${SurfaceCard} variant="compact" class="v2-command-panel">
      <details>
        <summary class="cursor-pointer text-sm text-[var(--color-fg-secondary)] font-medium select-none py-1">Maintenance</summary>
        <div class="mt-3 flex flex-wrap gap-2">
          <${ActionButton} variant="ghost" size="md" disabled=${maintenanceLoading.value || !maintenanceAccess.allowed}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: 'Maintenance', message: 'Run GC?' })
              if (confirmed) void runGarbageCollection()
            }}>
            ${maintenanceLoading.value ? '...' : 'Run GC'}<//>
        </div>
        ${maintenanceResult.value ? html`
          <pre class="mt-3 p-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/30 text-2xs text-text-body font-mono max-h-40 overflow-auto custom-scrollbar whitespace-pre-wrap">${maintenanceResult.value}</pre>
        ` : null}
      </details>
    <//>
    </div>
  `
}

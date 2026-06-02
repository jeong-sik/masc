// EmergencyStopControl — global header-loaded namespace pause/resume control.
//
// Reuses the flow-control-state signals (flowState/flowLoading/pauseWorkspace/
// resumeWorkspace), so this header control and the Command → Flow Control panel
// share state automatically through preact signals — pausing here flips the
// panel badge to 'Paused' without any extra wiring.
//
// Rendering contract:
//   - running + worker access → red "Emergency Stop" button (confirm-gated)
//   - paused                  → "Paused" badge (+ "Resume" button when allowed)
//   - unknown / initializing  → nothing (keeps the header uncluttered)

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Square, Play } from 'lucide-preact'
import { requestConfirm } from './common/confirm-dialog'
import { ActionButton } from './common/button'
import { CountBadge } from './common/badge'
import { shellAuthSummary } from '../store'
import { dashboardAuthAccess } from '../lib/dashboard-auth-access'
import {
  flowState,
  flowLoading,
  fetchPauseStatus,
  pauseWorkspace,
  resumeWorkspace,
} from './flow-control/flow-control-state'

export function EmergencyStopControl() {
  useEffect(() => { void fetchPauseStatus() }, [])

  const state = flowState.value
  const loading = flowLoading.value
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')

  if (state === 'paused') {
    return html`
      <div class="flex items-center gap-1.5" data-testid="emergency-stop-control">
        <${CountBadge} tone="warn">Paused<//>
        ${access.allowed ? html`
          <${ActionButton} variant="ghost" size="sm" disabled=${loading}
            onClick=${() => void resumeWorkspace()}>
            <span class="inline-flex items-center gap-1"><${Play} size=${12} />Resume</span>
          <//>
        ` : null}
      </div>
    `
  }

  if (state === 'running' && access.allowed) {
    return html`
      <${ActionButton} variant="danger" size="sm" disabled=${loading}
        testId="emergency-stop-control"
        onClick=${async () => {
          const confirmed = await requestConfirm({
            title: 'Emergency Stop',
            message: 'Pause the entire namespace now? All keeper activity halts until resumed.',
            tone: 'danger',
          })
          if (confirmed) void pauseWorkspace()
        }}>
        <span class="inline-flex items-center gap-1"><${Square} size=${12} />Emergency Stop</span>
      <//>
    `
  }

  return null
}

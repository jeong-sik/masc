// EmergencyStopControl — global header-loaded namespace pause/resume control.
//
// Reuses the flow-control-state signals (flowState/flowLoading/pauseWorkspace/
// resumeWorkspace), so this header control and the Command → Flow Control panel
// share state automatically through preact signals — pausing here flips the
// panel badge to 'Paused' without any extra wiring.
//
// Rendering contract:
//   - running + admin access → red "Emergency Stop" button (confirm-gated)
//   - paused                  → "Paused" badge (+ "Resume" button when allowed)
//   - unknown / initializing + admin → disabled state, same control footprint

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { CircleHelp, LoaderCircle, Square, Play } from 'lucide-preact'
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

const BUTTON_STATES = [
  { state: 'unknown', label: 'Pause unavailable', title: 'Workspace pause state is unavailable. Controls are disabled.', icon: CircleHelp },
  { state: 'initializing', label: 'Checking pause', title: 'Waiting for Workspace pause state. Controls are disabled.', icon: LoaderCircle },
  { state: 'running', label: 'Emergency Stop', title: 'Pause namespace automation and spawning.', icon: Square },
] as const

export function EmergencyStopControl() {
  useEffect(() => { void fetchPauseStatus() }, [])

  const state = flowState.value
  const loading = flowLoading.value
  const access = dashboardAuthAccess(shellAuthSummary.value, 'admin')

  if (!access.allowed) {
    if (state !== 'paused') return null
    return html`
      <div class="emergency-stop-control v2-shell-panel flex items-center gap-1.5" data-testid="emergency-stop-control">
        <${CountBadge} tone="warn">Paused<//>
      </div>
    `
  }

  // All presentations contribute their intrinsic size to one grid cell. Only
  // the current state is visible/accessible; measurement copies are inert,
  // disabled and carry no action handler. No guessed fixed width is needed.
  return html`
    <div class="emergency-stop-control inline-grid items-center" data-testid="emergency-stop-control"
      role="group" aria-label="Namespace pause control" aria-live="polite">
      ${BUTTON_STATES.map(presentation => {
        const active = state === presentation.state
        const canPause = active && presentation.state === 'running'
        return html`
          <div key=${presentation.state} class="emergency-stop-state"
            style=${{ gridArea: '1 / 1', visibility: active ? 'visible' : 'hidden' }}
            aria-hidden=${active ? undefined : 'true'} inert=${!active}>
            <${ActionButton} variant=${presentation.state === 'running' ? 'danger' : 'ghost'} size="sm" block
              disabled=${!canPause || loading} ariaBusy=${active && presentation.state === 'initializing'}
              title=${presentation.title} onClick=${canPause ? () => void pauseWorkspace() : undefined}>
              <span class="inline-flex items-center gap-1"><${presentation.icon} size=${12} />${presentation.label}</span>
            <//>
          </div>
        `
      })}
      <div class="emergency-stop-state flex items-center justify-center gap-1.5"
        style=${{ gridArea: '1 / 1', visibility: state === 'paused' ? 'visible' : 'hidden' }}
        aria-hidden=${state === 'paused' ? undefined : 'true'} inert=${state !== 'paused'}>
        <${CountBadge} tone="warn">Paused<//>
        <${ActionButton} variant="ghost" size="sm" disabled=${state !== 'paused' || loading}
          onClick=${state === 'paused' ? () => void resumeWorkspace() : undefined}>
          <span class="inline-flex items-center gap-1"><${Play} size=${12} />Resume</span>
        <//>
      </div>
    </div>
  `
}

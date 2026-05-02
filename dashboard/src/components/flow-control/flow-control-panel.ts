import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { requestConfirm } from '../common/confirm-dialog'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { CountBadge } from '../common/badge'
import { shellAuthSummary } from '../../store'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import {
  flowState, flowLoading, fetchPauseStatus, pauseRoom, resumeRoom,
  maintenanceResult, maintenanceLoading, runGarbageCollection, cleanupZombies,
} from './flow-control-state'

function stateLabel(s: string): string {
  return s === 'running'
    ? 'Running'
    : s === 'paused'
      ? 'Paused'
      : s === 'initializing'
        ? 'Initializing'
        : 'Unknown'
}

function stateTone(s: string): string {
  return s === 'running' ? 'ok' : s === 'paused' ? 'warn' : 'default'
}

export function FlowControlPanel() {
  useEffect(() => { void fetchPauseStatus() }, [])
  const loading = flowLoading.value
  const state = flowState.value
  const isPaused = state === 'paused'
  const isRunning = state === 'running'
  const isInitializing = state === 'initializing'
  const mutationAccess = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  return html`
    <${SurfaceCard} variant="compact" class="mb-4">
      <div class="flex items-center gap-3 mb-3">
        <h3 class="text-sm text-[var(--color-fg-secondary)] font-medium">Flow Control</h3>
        <${CountBadge} tone=${stateTone(state)}>${stateLabel(state)}<//>
      </div>
      ${mutationAccess.allowed ? null : html`
        <p class="mb-3 text-2xs text-[var(--color-status-warn)]">
          Control blocked: ${mutationAccess.reason ?? 'worker role is required.'}
        </p>
      `}
      <div class="flex flex-wrap gap-2">
        <${ActionButton} variant="ghost" size="md" disabled=${loading || isPaused || isInitializing || !mutationAccess.allowed} onClick=${() => void pauseRoom()}>
          ${loading && !isPaused ? '...' : 'Pause'}<//>
        <${ActionButton} variant="primary" size="md" disabled=${loading || isRunning || isInitializing || !mutationAccess.allowed} onClick=${() => void resumeRoom()}>
          ${loading && isPaused ? '...' : 'Resume'}<//>
      </div>
    <//>

    ${'' /* ── Maintenance ── */}
    <${SurfaceCard} variant="compact">
      <details>
        <summary class="cursor-pointer text-sm text-[var(--color-fg-secondary)] font-medium select-none py-1">Maintenance</summary>
        <div class="mt-3 flex flex-wrap gap-2">
          <${ActionButton} variant="ghost" size="md" disabled=${maintenanceLoading.value || !mutationAccess.allowed}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: 'Maintenance', message: 'Run GC?' })
              if (confirmed) void runGarbageCollection()
            }}>
            ${maintenanceLoading.value ? '...' : 'Run GC'}<//>
          <${ActionButton} variant="danger" size="md" disabled=${maintenanceLoading.value || !mutationAccess.allowed}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: 'Maintenance', message: 'Clean up zombie agents?', tone: 'danger' })
              if (confirmed) void cleanupZombies()
            }}>
            ${maintenanceLoading.value ? '...' : 'Clean Zombies'}<//>
        </div>
        ${maintenanceResult.value ? html`
          <pre class="mt-3 p-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/30 text-2xs text-text-body font-mono max-h-40 overflow-auto custom-scrollbar whitespace-pre-wrap">${maintenanceResult.value}</pre>
        ` : null}
      </details>
    <//>
  `
}

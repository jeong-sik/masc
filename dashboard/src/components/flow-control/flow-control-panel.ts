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
    ? '실행 중'
    : s === 'paused'
      ? '일시정지'
      : s === 'initializing'
        ? '초기화 중'
        : '알 수 없음'
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
        <h3 class="text-sm text-[var(--color-fg-secondary)] font-medium">흐름 제어</h3>
        <${CountBadge} tone=${stateTone(state)}>${stateLabel(state)}<//>
      </div>
      ${mutationAccess.allowed ? null : html`
        <p class="mb-3 text-2xs text-[var(--color-status-warn)]">
          제어 차단: ${mutationAccess.reason ?? 'worker 권한이 필요합니다.'}
        </p>
      `}
      <div class="flex flex-wrap gap-2">
        <${ActionButton} variant="ghost" size="md" disabled=${loading || isPaused || isInitializing || !mutationAccess.allowed} onClick=${() => void pauseRoom()}>
          ${loading && !isPaused ? '...' : '일시정지'}<//>
        <${ActionButton} variant="primary" size="md" disabled=${loading || isRunning || isInitializing || !mutationAccess.allowed} onClick=${() => void resumeRoom()}>
          ${loading && isPaused ? '...' : '재개'}<//>
      </div>
    <//>

    ${'' /* ── Maintenance ── */}
    <${SurfaceCard} variant="compact">
      <details>
        <summary class="cursor-pointer text-sm text-[var(--color-fg-secondary)] font-medium select-none py-1">유지보수</summary>
        <div class="mt-3 flex flex-wrap gap-2">
          <${ActionButton} variant="ghost" size="md" disabled=${maintenanceLoading.value || !mutationAccess.allowed}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: '유지보수', message: 'GC를 실행합니까?' })
              if (confirmed) void runGarbageCollection()
            }}>
            ${maintenanceLoading.value ? '...' : 'GC 실행'}<//>
          <${ActionButton} variant="danger" size="md" disabled=${maintenanceLoading.value || !mutationAccess.allowed}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: '유지보수', message: '좀비 에이전트를 정리합니까?', tone: 'danger' })
              if (confirmed) void cleanupZombies()
            }}>
            ${maintenanceLoading.value ? '...' : '좀비 정리'}<//>
        </div>
        ${maintenanceResult.value ? html`
          <pre class="mt-3 p-3 rounded border border-card-border/50 bg-card/30 text-2xs text-text-body font-mono max-h-40 overflow-auto custom-scrollbar whitespace-pre-wrap">${maintenanceResult.value}</pre>
        ` : null}
      </details>
    <//>
  `
}

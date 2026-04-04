import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { requestConfirm } from '../common/confirm-dialog'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { CountBadge } from '../common/badge'
import {
  flowState, flowLoading, fetchPauseStatus, pauseRoom, resumeRoom,
  roomStrategy, roomStrategyLoading, fetchRoomStrategy,
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
  return html`
    <${SurfaceCard} variant="compact" class="mb-4">
      <div class="flex items-center gap-3 mb-3">
        <h3 class="text-[13px] text-[var(--text-strong)] font-medium">흐름 제어</h3>
        <${CountBadge} tone=${stateTone(state)}>${stateLabel(state)}<//>
      </div>
      <div class="flex flex-wrap gap-2">
        <${ActionButton} variant="ghost" size="md" disabled=${loading || isPaused || isInitializing} onClick=${() => void pauseRoom()}>
          ${loading && !isPaused ? '...' : '일시정지'}<//>
        <${ActionButton} variant="primary" size="md" disabled=${loading || isRunning || isInitializing} onClick=${() => void resumeRoom()}>
          ${loading && isPaused ? '...' : '재개'}<//>
      </div>
    <//>

    ${'' /* ── Room Strategy ── */}
    <${SurfaceCard} variant="compact" class="mb-4">
      <details>
        <summary class="cursor-pointer text-[13px] text-[var(--text-strong)] font-medium select-none py-1">룸 전략</summary>
        <div class="mt-3">
          ${roomStrategy.value ? html`
            <div class="flex flex-col gap-1.5 mb-3">
              ${Object.entries(roomStrategy.value).map(([key, val]) => html`
                <div key=${key} class="flex items-center justify-between py-1.5 px-3 rounded-lg border border-card-border/50 bg-card/20 text-[12px]">
                  <span class="font-medium text-text-muted">${key}</span>
                  <span class="font-semibold text-text-strong font-mono">${String(val)}</span>
                </div>
              `)}
            </div>
          ` : html`<p class="text-[11px] text-text-dim mb-3">조회되지 않았습니다</p>`}
          <${ActionButton} variant="ghost" size="sm" disabled=${roomStrategyLoading.value}
            onClick=${() => void fetchRoomStrategy()}>
            ${roomStrategyLoading.value ? '...' : '조회'}<//>
        </div>
      </details>
    <//>

    ${'' /* ── Maintenance ── */}
    <${SurfaceCard} variant="compact">
      <details>
        <summary class="cursor-pointer text-[13px] text-[var(--text-strong)] font-medium select-none py-1">유지보수</summary>
        <div class="mt-3 flex flex-wrap gap-2">
          <${ActionButton} variant="ghost" size="md" disabled=${maintenanceLoading.value}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: '유지보수', message: 'GC를 실행합니까?' })
              if (confirmed) void runGarbageCollection()
            }}>
            ${maintenanceLoading.value ? '...' : 'GC 실행'}<//>
          <${ActionButton} variant="danger" size="md" disabled=${maintenanceLoading.value}
            onClick=${async () => {
              const confirmed = await requestConfirm({ title: '유지보수', message: '좀비 에이전트를 정리합니까?', tone: 'danger' })
              if (confirmed) void cleanupZombies()
            }}>
            ${maintenanceLoading.value ? '...' : '좀비 정리'}<//>
        </div>
        ${maintenanceResult.value ? html`
          <pre class="mt-3 p-3 rounded-lg border border-card-border/50 bg-card/30 text-[11px] text-text-body font-mono max-h-[160px] overflow-auto custom-scrollbar whitespace-pre-wrap">${maintenanceResult.value}</pre>
        ` : null}
      </details>
    <//>
  `
}

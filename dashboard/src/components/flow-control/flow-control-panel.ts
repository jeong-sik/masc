import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { TextInput } from '../common/input'
import { CountBadge } from '../common/badge'
import { flowState, flowLoading, fetchPauseStatus, pauseRoom, resumeRoom, interruptRoom } from './flow-control-state'

const showInterruptConfirm = signal(false)
const interruptReason = signal('')

function stateLabel(s: string): string { return s === 'running' ? '실행 중' : s === 'paused' ? '일시정지' : '알 수 없음' }
function stateTone(s: string): string { return s === 'running' ? 'ok' : s === 'paused' ? 'warn' : 'default' }

export function FlowControlPanel() {
  useEffect(() => { void fetchPauseStatus() }, [])
  const loading = flowLoading.value
  const state = flowState.value
  const isPaused = state === 'paused'
  const isRunning = state === 'running'
  return html`
    <${SurfaceCard} variant="compact" class="mb-4">
      <div class="flex items-center gap-3 mb-3">
        <h3 class="text-[13px] text-[var(--text-strong)] font-medium">흐름 제어</h3>
        <${CountBadge} tone=${stateTone(state)}>${stateLabel(state)}<//>
      </div>
      <div class="flex flex-wrap gap-2">
        <${ActionButton} variant="ghost" size="md" disabled=${loading || isPaused} onClick=${() => void pauseRoom()}>
          ${loading && !isPaused ? '...' : '일시정지'}<//>
        <${ActionButton} variant="primary" size="md" disabled=${loading || isRunning} onClick=${() => void resumeRoom()}>
          ${loading && isPaused ? '...' : '재개'}<//>
        <${ActionButton} variant="danger" size="md" disabled=${loading}
          onClick=${() => { showInterruptConfirm.value = !showInterruptConfirm.value }}>인터럽트<//>
        <${ActionButton} variant="subtle" size="sm" class="ml-auto" onClick=${() => void fetchPauseStatus()}>새로고침<//>
      </div>
      ${showInterruptConfirm.value ? html`
        <div class="mt-3 rounded-lg border border-[rgba(251,113,133,0.4)] bg-[rgba(251,113,133,0.06)] p-3">
          <p class="text-[11px] text-[#fda4af] mb-2">인터럽트는 현재 진행 중인 모든 에이전트 작업을 중단합니다.</p>
          <div class="flex gap-2 items-end">
            <div class="flex-1">
              <${TextInput} value=${interruptReason.value} placeholder="사유 (선택)"
                onInput=${(e: Event) => { interruptReason.value = (e.target as HTMLInputElement).value }} />
            </div>
            <${ActionButton} variant="danger" size="md" disabled=${loading}
              onClick=${() => { void interruptRoom(interruptReason.value || undefined).then(() => { showInterruptConfirm.value = false; interruptReason.value = '' }) }}>
              ${loading ? '...' : '실행'}<//>
            <${ActionButton} variant="ghost" size="md" onClick=${() => { showInterruptConfirm.value = false }}>취소<//>
          </div>
        </div>
      ` : null}
    <//>
  `
}

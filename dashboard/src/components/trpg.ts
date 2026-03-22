import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { refreshTrpg, trpgLoading, trpgRoom, trpgState } from '../store'

/** When true the TRPG backend returned 410 Gone (module archived). */
const trpgArchived = signal(false)

async function safeFetchTrpg(): Promise<void> {
  try {
    await refreshTrpg()
  } catch (err: unknown) {
    // Detect 410 Gone — the TRPG module has been archived server-side.
    if (
      err instanceof Error
      && /\b410\b/.test(err.message)
    ) {
      trpgArchived.value = true
    }
  }
}

export function Trpg() {
  const state = trpgState.value
  const loading = trpgLoading.value
  const archived = trpgArchived.value

  useEffect(() => {
    if (!state && !loading && !archived) {
      void safeFetchTrpg()
    }
  }, [state, loading, archived])

  if (archived) {
    return html`
      <div class="empty-state">
        <div style="margin-bottom: 8px; font-size: 1.1em;">TRPG 모듈은 아카이브되었습니다</div>
        <div style="font-size: 0.9em; opacity: 0.7;">이 모듈은 더 이상 활성 상태가 아닙니다. 과거 세션 기록은 서버 로그에 남아 있습니다.</div>
      </div>
    `
  }

  if (loading && !state) {
    return html`<div class="empty-state">TRPG 상태를 불러오는 중...</div>`
  }

  if (!state) {
    return html`
      <div class="empty-state">
        <div style="margin-bottom: 12px;">활성 TRPG 세션이 없습니다.</div>
        <button class="control-btn rounded-lg ghost" onClick=${() => void safeFetchTrpg()}>새로고침</button>
      </div>
    `
  }

  return html`
    <div class="monitor-summary-grid">
      <div class="monitor-summary-card rounded-xl">
        <div class="monitor-summary-label">ROOM</div>
        <div class="monitor-summary-value">${trpgRoom.value || state.session?.room || '-'}</div>
      </div>
      <div class="monitor-summary-card rounded-xl">
        <div class="monitor-summary-label">SESSION</div>
        <div class="monitor-summary-value">${state.session?.status ?? 'active'}</div>
      </div>
      <div class="monitor-summary-card rounded-xl">
        <div class="monitor-summary-label">PARTY</div>
        <div class="monitor-summary-value">${state.party.length}</div>
      </div>
      <div class="monitor-summary-card rounded-xl">
        <div class="monitor-summary-label">EVENTS</div>
        <div class="monitor-summary-value">${state.story_log.length}</div>
      </div>
    </div>
  `
}

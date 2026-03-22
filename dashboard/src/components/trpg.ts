import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { refreshTrpg, trpgLoading, trpgRoom, trpgState } from '../store'

export function Trpg() {
  const state = trpgState.value
  const loading = trpgLoading.value

  useEffect(() => {
    if (!state && !loading) {
      void refreshTrpg()
    }
  }, [state, loading])

  if (loading && !state) {
    return html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">TRPG 상태를 불러오는 중...</div>`
  }

  if (!state) {
    return html`
      <div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">
        <div style="margin-bottom: 12px;">활성 TRPG 세션이 없습니다.</div>
        <button class="control-btn rounded-lg ghost" onClick=${() => void refreshTrpg()}>새로고침</button>
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

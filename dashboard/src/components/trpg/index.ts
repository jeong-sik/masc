// TRPG — Main entry component

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { trpgState, trpgLoading, trpgRoom, refreshTrpg } from '../../store'
import { realtimeNowMs, trpgScreen } from './helpers'
import { SessionOutcome } from './sub-components'
import { TrpgScreenTabs, OverviewView, TimelineView, ControlView } from './views'

export function Trpg() {
  const state = trpgState.value
  const loading = trpgLoading.value

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.setInterval !== 'function') return undefined
    const ticker = window.setInterval(() => {
      realtimeNowMs.value = Date.now()
    }, 1000)
    return () => {
      window.clearInterval(ticker)
    }
  }, [])

  if (loading && !state) {
    return html`<div class="loading-indicator">Loading TRPG state...</div>`
  }

  if (!state) {
    return html`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${() => refreshTrpg()}>Refresh</button>
      </div>
    `
  }

  const party = state.party ?? []
  const events = state.story_log ?? []
  const outcome = state.outcome
  const screen = trpgScreen.value
  const nowMs = realtimeNowMs.value

  return html`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${trpgRoom.value || state.session?.room || '-'} · phase: ${state.current_round?.phase ?? state.session?.status ?? '-'}
        </div>
        <button class="trpg-run-btn secondary" onClick=${() => refreshTrpg()}>새로고침</button>
      </div>

      <${SessionOutcome} outcome=${outcome} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${state.session?.status ?? 'active'}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${state.current_round?.round_number ?? 0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${party.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${events.length}</div>
        </div>
      </div>

      <${TrpgScreenTabs} active=${screen} />

      ${screen === 'overview'
        ? html`<${OverviewView} state=${state} />`
        : screen === 'timeline'
          ? html`<${TimelineView} state=${state} />`
          : html`<${ControlView} state=${state} nowMs=${nowMs} />`}
    </div>
  `
}

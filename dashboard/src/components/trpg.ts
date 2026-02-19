// TRPG tab — Game state overview, story log, controls

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { trpgState, trpgLoading, refreshTrpg } from '../store'
import type { TrpgActor, TrpgState, TrpgEvent } from '../types'

function ActorCard({ actor }: { actor: TrpgActor }) {
  return html`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${actor.name}</span>
        <${StatusBadge} status=${actor.status ?? 'idle'} />
        <span class="pill">${actor.role}</span>
      </div>
      ${actor.stats
        ? html`
          <div class="trpg-actor-stats">
            <span>HP ${actor.stats.hp}/${actor.stats.max_hp}</span>
            <span>STR ${actor.stats.strength}</span>
            <span>DEX ${actor.stats.dexterity}</span>
          </div>
        `
        : null}
    </div>
  `
}

function StoryLog({ state }: { state: TrpgState }) {
  const events = state.story_log ?? []
  return html`
    <div class="trpg-story">
      ${events.length === 0
        ? html`<div class="empty-state">No story events yet</div>`
        : events.slice(-20).map((e: TrpgEvent, i: number) => html`
            <div key=${i} class="trpg-event ${e.type ?? ''}">
              ${e.dice_roll
                ? html`<span class="trpg-dice">[${e.dice_roll.notation}: ${e.dice_roll.total}]</span>`
                : null}
              <span class="trpg-event-text">${e.content ?? ''}</span>
            </div>
          `)}
    </div>
  `
}

export function Trpg() {
  const state = trpgState.value
  const loading = trpgLoading.value

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

  return html`
    <div>
      <div class="stats-grid" style="margin-bottom: 20px">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size: 18px">${state.session?.status ?? 'Active'}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${state.current_round?.round_number ?? 0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${state.party?.length ?? 0}</div>
        </div>
      </div>

      <div class="grid-2col">
        <${Card} title="Party" class="section">
          <div class="trpg-actor-list">
            ${(state.party ?? []).map((a: TrpgActor) =>
              html`<${ActorCard} key=${a.name} actor=${a} />`
            )}
          </div>
        <//>

        <${Card} title="Story" class="section">
          <${StoryLog} state=${state} />
        <//>
      </div>
    </div>
  `
}

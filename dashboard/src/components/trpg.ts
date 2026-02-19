// TRPG tab — Game state, story log, ASCII map, round controls, keeper view
// CSS classes: .trpg-layout, .trpg-actor-list, .trpg-hp-bar, .trpg-map,
//   .trpg-control-box, .trpg-round-list, .trpg-keeper-chip (components.css)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { trpgState, trpgLoading, trpgRoom, refreshTrpg } from '../store'
import { runTrpgRound, rollTrpgDice, advanceTrpgTurn } from '../api'
import type { TrpgActor, TrpgState, TrpgEvent, TrpgCharacterStats } from '../types'

// ── Local control state ──────────────────────────────────

const diceNotation = signal('1d20')
const runStatus = signal<'idle' | 'running' | 'ok' | 'error'>('idle')

// ── Helpers ──────────────────────────────────────────────

function hpClass(hp: number, max: number): string {
  const pct = max > 0 ? (hp / max) * 100 : 0
  if (pct > 50) return 'hp-high'
  if (pct > 25) return 'hp-mid'
  return 'hp-low'
}

function hpPct(hp: number, max: number): number {
  return max > 0 ? Math.round((hp / max) * 100) : 0
}

// ── Sub-components ───────────────────────────────────────

function HpBar({ hp, max }: { hp: number; max: number }) {
  const pct = hpPct(hp, max)
  const cls = hpClass(hp, max)
  return html`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${cls}" style="width:${pct}%" />
    </div>
  `
}

function StatGrid({ stats }: { stats: TrpgCharacterStats }) {
  const entries = [
    { label: 'STR', value: stats.strength },
    { label: 'DEX', value: stats.dexterity },
    { label: 'CON', value: stats.constitution },
    { label: 'INT', value: stats.intelligence },
    { label: 'WIS', value: stats.wisdom },
    { label: 'CHA', value: stats.charisma },
  ]
  return html`
    <div class="trpg-actor-stats">
      ${entries.map(e => html`<span>${e.label} ${e.value}</span>`)}
    </div>
  `
}

function KeeperChip({ keeper, role }: { keeper?: string; role: string }) {
  if (!keeper) return null
  const roleTag = role === 'dm' ? 'dm' : 'player'
  return html`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${roleTag}">${roleTag}</span>
      ${keeper}
    </span>
  `
}

function ActorCard({ actor }: { actor: TrpgActor }) {
  return html`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${actor.name}</span>
        <${StatusBadge} status=${actor.status ?? 'idle'} />
        <span class="pill">${actor.role}</span>
        <${KeeperChip} keeper=${actor.keeper} role=${actor.role} />
      </div>
      ${actor.stats
        ? html`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${actor.stats.hp}/${actor.stats.max_hp}
              ${actor.stats.max_mp > 0
                ? html`<span style="margin-left:8px;">MP ${actor.stats.mp}/${actor.stats.max_mp}</span>`
                : null}
              <span style="margin-left:auto; font-size:10px;">Lv ${actor.stats.level}</span>
            </div>
            <${HpBar} hp=${actor.stats.hp} max=${actor.stats.max_hp} />
            <${StatGrid} stats=${actor.stats} />
          </div>
        `
        : null}
    </div>
  `
}

function AsciiMap({ mapStr }: { mapStr: string }) {
  return html`<pre class="trpg-map">${mapStr}</pre>`
}

function StoryLog({ events }: { events: TrpgEvent[] }) {
  if (events.length === 0) {
    return html`<div class="empty-state" style="font-size:13px">No story events yet</div>`
  }

  return html`
    <div class="trpg-story">
      ${events.slice(-30).map((e: TrpgEvent, i: number) => html`
        <div key=${i} class="trpg-event ${e.type ?? ''}">
          ${e.actor ? html`<strong>${e.actor}</strong>${' '}` : null}
          ${e.dice_roll
            ? html`<span class="trpg-dice">[${e.dice_roll.notation}: ${e.dice_roll.rolls?.join(',')} = ${e.dice_roll.total}${e.dice_roll.modifier ? ` +${e.dice_roll.modifier}` : ''}]</span>${' '}`
            : null}
          <span class="trpg-event-text">${e.content ?? ''}</span>
          <span style="float:right; font-size:10px; color:#555;"><${TimeAgo} timestamp=${e.timestamp} /></span>
        </div>
      `)}
    </div>
  `
}

function RoundHistory({ state }: { state: TrpgState }) {
  const rounds = state.history ?? []
  if (rounds.length === 0) return null

  return html`
    <div class="trpg-round-list">
      ${rounds.slice(-10).map(s => html`
        <div class="trpg-round-item ${s.status}">
          <span>Session ${s.id.slice(0, 8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${s.round} — ${s.status}
          </span>
        </div>
      `)}
    </div>
  `
}

// ── Controls ─────────────────────────────────────────────

function ControlBox({ state }: { state: TrpgState }) {
  const room = trpgRoom.value || state.session?.room || ''
  const status = runStatus.value

  const handleRunRound = async () => {
    if (!room) { showToast('No room set', 'error'); return }
    runStatus.value = 'running'
    try {
      await runTrpgRound(room)
      runStatus.value = 'ok'
      showToast('Round executed', 'success')
      refreshTrpg()
    } catch {
      runStatus.value = 'error'
      showToast('Round failed', 'error')
    }
  }

  const handleAdvanceTurn = async () => {
    if (!room) return
    try {
      await advanceTrpgTurn(room)
      showToast('Turn advanced', 'success')
      refreshTrpg()
    } catch {
      showToast('Advance failed', 'error')
    }
  }

  const handleRollDice = async () => {
    const notation = diceNotation.value.trim()
    if (!room || !notation) return
    try {
      await rollTrpgDice(room, notation)
      showToast(`Rolled ${notation}`, 'success')
      refreshTrpg()
    } catch {
      showToast('Dice roll failed', 'error')
    }
  }

  return html`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:flex; gap:4px;">
            <input
              type="text"
              value=${diceNotation.value}
              onInput=${(e: Event) => { diceNotation.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') handleRollDice() }}
              placeholder="1d20+3"
              style="flex:1;"
            />
            <button class="trpg-run-btn secondary" onClick=${handleRollDice}>Roll</button>
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button
              class="trpg-run-btn recommend"
              onClick=${handleRunRound}
              disabled=${status === 'running'}
            >
              ${status === 'running' ? 'Running...' : 'Run Round'}
            </button>
            <button class="trpg-run-btn secondary" onClick=${handleAdvanceTurn}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${status !== 'idle'
        ? html`<div class="trpg-run-status ${status}">${status === 'running' ? 'Processing...' : status === 'ok' ? 'Done' : 'Failed'}</div>`
        : null}
    </div>
  `
}

function NextAction({ state }: { state: TrpgState }) {
  const round = state.current_round
  if (!round) return null

  return html`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${round.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${round.phase}</div>
      ${round.events.length > 0
        ? html`<div class="trpg-next-action-target">
            Last: ${(round.events[round.events.length - 1] as TrpgEvent).content?.slice(0, 80)}
          </div>`
        : null}
    </div>
  `
}

// ── Main TRPG component ──────────────────────────────────

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

  const party = state.party ?? []
  const events = state.story_log ?? []

  return html`
    <div>
      ${'' /* Summary stats */}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${state.session?.status ?? 'Active'}</div>
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

      ${'' /* Next action banner */}
      <${NextAction} state=${state} />

      ${'' /* 2-column layout: main (story + map) | sidebar (party + controls) */}
      <div class="trpg-layout">
        <div>
          ${'' /* Story log */}
          <${Card} title="Story Log (${events.length})">
            <${StoryLog} events=${events} />
          <//>

          ${'' /* ASCII map */}
          ${state.map
            ? html`
              <${Card} title="Map" style="margin-top:16px;">
                <${AsciiMap} mapStr=${state.map} />
              <//>`
            : null}
        </div>

        <div class="trpg-sidebar">
          ${'' /* Controls */}
          <${Card} title="Controls">
            <${ControlBox} state=${state} />
          <//>

          ${'' /* Party list */}
          <${Card} title="Party (${party.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${party.map((a: TrpgActor) =>
                html`<${ActorCard} key=${a.id ?? a.name} actor=${a} />`
              )}
              ${party.length === 0
                ? html`<div class="empty-state" style="font-size:13px">No actors</div>`
                : null}
            </div>
          <//>

          ${'' /* Round history */}
          ${state.history && state.history.length > 0
            ? html`
              <${Card} title="History (${state.history.length})" style="margin-top:16px;">
                <${RoundHistory} state=${state} />
              <//>`
            : null}
        </div>
      </div>
    </div>
  `
}

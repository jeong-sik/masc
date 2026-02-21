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

const selectedActorId = signal('')
const diceAction = signal('ability_check')
const diceStatValue = signal('10')
const diceDc = signal('12')
const diceRawD20 = signal('')
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

const TRAIT_HINTS: Record<string, string> = {
  pragmatic: '리스크보다 확실한 이득을 우선합니다.',
  frugal: '자원 소모를 줄이고 효율을 챙깁니다.',
  impatient: '짧은 템포로 즉시 압박을 선호합니다.',
  stubborn: '한 번 정한 전술을 끝까지 밀어붙입니다.',
  protective: '아군 피해를 줄이는 선택을 우선합니다.',
  'honor-bound': '약속과 규율을 지키는 행동에 보너스가 납니다.',
  intense: '집중 화력을 짧게 폭발시킵니다.',
  empathetic: '아군/약자 보호 쪽 선택 확률이 높아집니다.',
  fatalistic: '위험을 감수하는 고배수 선택을 탑니다.',
  suspicious: '함정/매복 경계 행동을 우선합니다.',
  precise: '단일 목표를 정확히 노리는 경향입니다.',
  vengeful: '직전 위협 대상에게 강하게 반응합니다.',
  aggressive: '공격적인 전진 행동을 우선합니다.',
  opportunistic: '빈틈이 열리면 즉시 추격합니다.',
}

const SKILL_HINTS: Record<string, string> = {
  supply_scan: '전장/자원 상태를 스캔해 약한 지점을 찾습니다.',
  ration_shift: '소모를 줄이고 지속 전투 능력을 확보합니다.',
  logistics_patch: '무너진 운영 라인을 빠르게 복구합니다.',
  frontline_shield: '전열에서 아군 피해를 흡수합니다.',
  oath_intercept: '핵심 타깃을 가로막아 위협을 차단합니다.',
  morale_anchor: '아군 안정도를 높여 붕괴를 막습니다.',
  omen_trace: '다음 위험 신호를 먼저 감지합니다.',
  arc_flash: '짧은 순간 광역 압박을 넣습니다.',
  ward_bloom: '방어 장막을 펼쳐 생존률을 올립니다.',
  mark_prey: '우선 제거 대상을 지정합니다.',
  silent_route: '은밀한 진입 경로를 확보합니다.',
  finisher_strike: '약화된 적을 마무리하는 일격입니다.',
  shadow_claw: '근접 급습으로 출혈 피해를 노립니다.',
  lunge: '짧은 돌진으로 전열을 흔듭니다.',
}

function prettyToken(token: string): string {
  const trimmed = token.trim()
  if (!trimmed) return token
  return trimmed
    .split(/[_-]+/g)
    .filter(part => part.length > 0)
    .map(part => part[0] ? `${part[0].toUpperCase()}${part.slice(1)}` : part)
    .join(' ')
}

function explainTrait(trait: string): string {
  const key = trait.trim().toLowerCase()
  return TRAIT_HINTS[key] ?? '행동 선택 가중치에 영향을 주는 성향입니다.'
}

function explainSkill(skill: string): string {
  const key = skill.trim().toLowerCase()
  return SKILL_HINTS[key] ?? '상황에 따라 선택되는 전술 액션입니다.'
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
  const archetype = actor.archetype?.trim()
  const persona = actor.persona?.trim()
  const traits = actor.traits ?? []
  const skills = actor.skills ?? []

  return html`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${actor.name}</span>
        <${StatusBadge} status=${actor.status ?? 'idle'} />
        <span class="pill trpg-role-pill trpg-role-${actor.role}">${actor.role}</span>
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
      ${archetype ? html`<div class="trpg-actor-meta">Archetype: ${prettyToken(archetype)}</div>` : null}
      ${persona ? html`<div class="trpg-actor-persona">${persona}</div>` : null}
      ${traits.length > 0
        ? html`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${traits.map(trait => html`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${prettyToken(trait)}</span>
                  <span class="trpg-annot-desc">${explainTrait(trait)}</span>
                </span>
              `)}
            </div>
          </div>
        `
        : null}
      ${skills.length > 0
        ? html`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${skills.map(skill => html`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${prettyToken(skill)}</span>
                  <span class="trpg-annot-desc">${explainSkill(skill)}</span>
                </span>
              `)}
            </div>
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
  const actors = state.party ?? []
  const selectedActor = actors.find(a => a.id === selectedActorId.value)
  if (!selectedActor && actors.length > 0) {
    const firstActor = actors[0]
    if (firstActor) selectedActorId.value = firstActor.id
  }

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
    if (!room) return
    const actorId = selectedActorId.value.trim()
    if (!actorId) {
      showToast('Select actor first', 'warning')
      return
    }
    const statValue = Number.parseInt(diceStatValue.value, 10)
    const dc = Number.parseInt(diceDc.value, 10)
    if (Number.isNaN(statValue) || Number.isNaN(dc)) {
      showToast('Stat/DC must be numbers', 'warning')
      return
    }
    const rawParsed = Number.parseInt(diceRawD20.value, 10)
    const rawD20 = diceRawD20.value.trim() === '' || Number.isNaN(rawParsed)
      ? undefined
      : rawParsed
    try {
      await rollTrpgDice({
        roomId: room,
        actorId,
        action: diceAction.value.trim() || 'ability_check',
        statValue,
        dc,
        rawD20,
      })
      showToast('Dice rolled', 'success')
      refreshTrpg()
    } catch {
      showToast('Dice roll failed', 'error')
    }
  }

  return html`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${room}
            onInput=${(e: Event) => { trpgRoom.value = (e.target as HTMLInputElement).value }}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${selectedActorId.value}
            onChange=${(e: Event) => { selectedActorId.value = (e.target as HTMLSelectElement).value }}
          >
            <option value="">Select actor</option>
            ${actors.map(a => html`<option value=${a.id}>${a.name} (${a.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              type="text"
              value=${diceAction.value}
              onInput=${(e: Event) => { diceAction.value = (e.target as HTMLInputElement).value }}
              placeholder="action"
            />
            <input
              type="text"
              value=${diceStatValue.value}
              onInput=${(e: Event) => { diceStatValue.value = (e.target as HTMLInputElement).value }}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${diceDc.value}
              onInput=${(e: Event) => { diceDc.value = (e.target as HTMLInputElement).value }}
              placeholder="dc (e.g. 15)"
            />
            <input
              type="text"
              value=${diceRawD20.value}
              onInput=${(e: Event) => { diceRawD20.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') handleRollDice() }}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${handleRollDice}>Roll</button>
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

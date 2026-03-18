// TRPG sub-components — Display components for party, story, timeline, etc.

import { html } from 'htm/preact'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import type { TrpgActor, TrpgState, TrpgEvent, TrpgCharacterStats } from '../../types'
import {
  hpClass,
  hpPct,
  BASE_STAT_KEYS,
  prettyToken,
  explainTrait,
  explainSkill,
  eventActorLabel,
  eventTimeLabel,
  timelineActorFilter,
  timelineTypeFilter,
  timelinePhaseFilter,
} from './helpers'

export function HpBar({ hp, max }: { hp: number; max: number }) {
  const pct = hpPct(hp, max)
  const cls = hpClass(hp, max)
  return html`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${cls}" style="width:${pct}%" />
    </div>
  `
}

export function StatGrid({ stats }: { stats: TrpgCharacterStats }) {
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

export function KeeperChip({ keeper, role }: { keeper?: string; role: string }) {
  if (!keeper) return null
  const roleTag = role === 'dm' ? 'dm' : 'player'
  return html`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${roleTag}">${roleTag}</span>
      ${keeper}
    </span>
  `
}

export function ActorCard({ actor }: { actor: TrpgActor }) {
  const archetype = actor.archetype?.trim()
  const persona = actor.persona?.trim()
  const portrait = actor.portrait?.trim()
  const background = actor.background?.trim()
  const traits = actor.traits ?? []
  const skills = actor.skills ?? []
  const customStats = Object.entries(actor.stats_raw ?? {})
    .filter(([_, value]) => Number.isFinite(value))
    .filter(([key]) => !BASE_STAT_KEYS.has(key.toLowerCase()))

  return html`
    <div class="trpg-actor">
      ${portrait
        ? html`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${portrait}
              alt=${`${actor.name} portrait`}
              loading="lazy"
              onError=${(e: Event) => {
                const target = e.target as HTMLImageElement | null
                if (!target) return
                target.style.display = 'none'
              }}
            />
          </div>
        `
        : null}
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
      ${background ? html`<div class="trpg-actor-meta">Background: ${background}</div>` : null}
      ${persona ? html`<div class="trpg-actor-persona">${persona}</div>` : null}
      ${customStats.length > 0
        ? html`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${customStats.map(([key, value]) => html`
                <span class="trpg-custom-stat-chip">${prettyToken(key)} ${value}</span>
              `)}
            </div>
          </div>
        `
        : null}
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

export function AsciiMap({ mapStr }: { mapStr: string }) {
  return html`<pre class="trpg-map">${mapStr}</pre>`
}

export function StoryLog({ events, emptyLabel = '아직 이벤트가 없습니다.' }: { events: TrpgEvent[]; emptyLabel?: string }) {
  if (events.length === 0) {
    return html`<div class="empty-state" style="font-size:13px">${emptyLabel}</div>`
  }

  return html`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${events.map((e: TrpgEvent, i: number) => html`
        <div key=${i} class="trpg-event ${e.type ?? ''}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${eventTimeLabel(e)}</span>
            <span class="trpg-event-meta">${e.phase ?? 'phase:-'}</span>
            <span class="trpg-event-meta">${e.type ?? 'type:-'}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${eventActorLabel(e)}</strong>
            ${' '}
          ${e.dice_roll
            ? html`<span class="trpg-dice">[${e.dice_roll.notation}: ${e.dice_roll.rolls?.join(',')} = ${e.dice_roll.total}${e.dice_roll.modifier ? ` +${e.dice_roll.modifier}` : ''}]</span>${' '}`
            : null}
            <span class="trpg-event-text">${e.content ?? ''}</span>
            <span class="trpg-event-ts"><${TimeAgo} timestamp=${e.timestamp} /></span>
          </div>
        </div>
      `)}
    </div>
  `
}

export function TimelinePanel({ events }: { events: TrpgEvent[] }) {
  const NONE_VALUE = '__none__'
  const actorFilter = timelineActorFilter.value
  const typeFilter = timelineTypeFilter.value
  const phaseFilter = timelinePhaseFilter.value

  const actorOptions = Array.from(
    new Set(
      events
        .map(eventActorLabel)
        .map(v => v.trim())
        .filter(v => v !== ''),
    ),
  ).sort((a, b) => a.localeCompare(b))
  const typeOptions = Array.from(
    new Set(
      events
        .map(e => (e.type ?? '').trim())
        .filter(v => v !== ''),
    ),
  ).sort((a, b) => a.localeCompare(b))
  const hasEmptyType = events.some(e => (e.type ?? '').trim() === '')
  const phaseOptions = Array.from(
    new Set(
      events
        .map(e => (e.phase ?? '').trim())
        .filter(v => v !== ''),
    ),
  ).sort((a, b) => a.localeCompare(b))
  const hasEmptyPhase = events.some(e => (e.phase ?? '').trim() === '')

  const filteredEvents = events.filter(event => {
    if (actorFilter !== 'all' && eventActorLabel(event) !== actorFilter) return false
    const type = (event.type ?? '').trim()
    const phase = (event.phase ?? '').trim()
    if (typeFilter === NONE_VALUE) {
      if (type !== '') return false
    } else if (typeFilter !== 'all' && type !== typeFilter) {
      return false
    }
    if (phaseFilter === NONE_VALUE) {
      if (phase !== '') return false
    } else if (phaseFilter !== 'all' && phase !== phaseFilter) {
      return false
    }
    return true
  })

  return html`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${actorFilter} onChange=${(e: Event) => { timelineActorFilter.value = (e.target as HTMLSelectElement).value }}>
          <option value="all">all</option>
          ${actorOptions.map(actor => html`<option value=${actor}>${actor}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${typeFilter} onChange=${(e: Event) => { timelineTypeFilter.value = (e.target as HTMLSelectElement).value }}>
          <option value="all">all</option>
          ${hasEmptyType ? html`<option value=${NONE_VALUE}>(none)</option>` : null}
          ${typeOptions.map(type => html`<option value=${type}>${type}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${phaseFilter} onChange=${(e: Event) => { timelinePhaseFilter.value = (e.target as HTMLSelectElement).value }}>
          <option value="all">all</option>
          ${hasEmptyPhase ? html`<option value=${NONE_VALUE}>(none)</option>` : null}
          ${phaseOptions.map(phase => html`<option value=${phase}>${phase}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${() => {
          timelineActorFilter.value = 'all'
          timelineTypeFilter.value = 'all'
          timelinePhaseFilter.value = 'all'
        }}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${filteredEvents.length} / 전체 ${events.length}
      </span>
    </div>
    <${StoryLog} events=${filteredEvents.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `
}

export function SessionOutcome({ outcome }: { outcome?: TrpgState['outcome'] }) {
  if (!outcome) return null

  const normalizeOutcomeText = (value: string): string => {
    const normalized = value.trim()
    if (!normalized) return normalized
    if (/[A-Z]/.test(normalized) && !normalized.includes(' ')) {
      return normalized
        .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
        .replace(/[_\.]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim()
    }
    return normalized.replace(/[_\.]/g, ' ').replace(/\s+/g, ' ').trim()
  }

  const label =
    outcome.result === 'victory'
      ? '승리'
      : outcome.result === 'defeat'
        ? '패배'
        : outcome.result === 'draw'
          ? '무승부'
          : '종료'
  const color = outcome.result === 'victory' ? '#34d399' : outcome.result === 'defeat' ? '#f87171' : '#9ca3af'
  const meta = [
    outcome.reason ? `원인: ${normalizeOutcomeText(outcome.reason)}` : null,
    outcome.phase ? `페이즈: ${normalizeOutcomeText(outcome.phase)}` : null,
    typeof outcome.turn === 'number' ? `턴: ${outcome.turn}` : null,
  ].filter(Boolean).join(' · ')

  return html`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${color}; margin-top:4px;">${label}</div>
      ${outcome.summary
        ? html`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${normalizeOutcomeText(outcome.summary)}</div>`
        : null}
      ${meta ? html`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${meta}</div>` : null}
    </div>
  `
}

export function RoundHistory({ state }: { state: TrpgState }) {
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

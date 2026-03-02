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
import {
  runTrpgRound,
  rollTrpgDice,
  advanceTrpgTurn,
  fetchTrpgJoinEligibility,
  requestTrpgMidJoin,
  type TrpgRoundRunResult,
} from '../api'
import type { TrpgActor, TrpgState, TrpgEvent, TrpgCharacterStats } from '../types'

// ── Local control state ──────────────────────────────────

const selectedActorId = signal('')
const diceAction = signal('ability_check')
const diceStatValue = signal('10')
const diceDc = signal('12')
const diceRawD20 = signal('')
const runStatus = signal<'idle' | 'running' | 'ok' | 'error'>('idle')
const joinActorId = signal('')
const joinKeeper = signal('keeper-late')
const joinRole = signal<'player' | 'npc' | 'dm'>('player')
const joinActorName = signal('')
const joinStatus = signal<'idle' | 'checking' | 'requesting' | 'ok' | 'error'>('idle')
const joinEligibility = signal<Record<string, unknown> | null>(null)
const lastRoundRun = signal<TrpgRoundRunResult | null>(null)
type TrpgScreen = 'overview' | 'timeline' | 'control'
const trpgScreen = signal<TrpgScreen>('overview')
const timelineActorFilter = signal('all')
const timelineTypeFilter = signal('all')
const timelinePhaseFilter = signal('all')
const CONTROL_UNLOCK_WINDOW_MS = 120_000
const controlUnlockUntilMs = signal<number | null>(null)

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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function recString(obj: Record<string, unknown>, key: string, fallback = ''): string {
  const value = obj[key]
  return typeof value === 'string' ? value : fallback
}

function recNumber(obj: Record<string, unknown>, key: string, fallback = 0): number {
  const value = obj[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function recBool(obj: Record<string, unknown>, key: string, fallback = false): boolean {
  const value = obj[key]
  return typeof value === 'boolean' ? value : fallback
}

function eventActorLabel(event: TrpgEvent): string {
  const raw = event.actor_name ?? event.actor ?? event.actor_id ?? 'system'
  const trimmed = raw.trim()
  return trimmed === '' ? 'system' : trimmed
}

function eventTimeLabel(event: TrpgEvent): string {
  const ts = event.timestamp?.trim() ?? ''
  return ts || '-'
}

function setTrpgScreen(next: TrpgScreen): void {
  trpgScreen.value = next
}

function isControlLocked(nowMs: number): boolean {
  const unlockUntil = controlUnlockUntilMs.value
  return unlockUntil == null || unlockUntil <= nowMs
}

function controlRemainingSeconds(nowMs: number): number {
  const unlockUntil = controlUnlockUntilMs.value
  if (unlockUntil == null || unlockUntil <= nowMs) return 0
  return Math.max(0, Math.ceil((unlockUntil - nowMs) / 1000))
}

function relockControl(): void {
  controlUnlockUntilMs.value = null
}

function browserConfirm(message: string): boolean {
  if (typeof window === 'undefined' || typeof window.confirm !== 'function') return true
  return window.confirm(message)
}

function unlockControl(room: string, phase: string): void {
  const ok = browserConfirm(
    [
      '관전 모드 잠금을 해제하시겠습니까?',
      `ROOM: ${room || '-'}`,
      `PHASE: ${phase || '-'}`,
      '해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)',
    ].join('\n'),
  )
  if (!ok) return
  controlUnlockUntilMs.value = Date.now() + CONTROL_UNLOCK_WINDOW_MS
  showToast('조작 잠금이 120초 동안 해제되었습니다.', 'warning')
}

function ensureUnlocked(nowMs: number): boolean {
  if (isControlLocked(nowMs)) {
    showToast('관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.', 'warning')
    return false
  }
  return true
}

function confirmRiskAction(actionLabel: string, room: string, phase: string): boolean {
  return browserConfirm(
    [
      `[위험 액션 확인] ${actionLabel}`,
      `ROOM: ${room || '-'}`,
      `PHASE: ${phase || '-'}`,
      '이 액션은 즉시 실행되며 되돌리기 어렵습니다.',
      '계속 진행하시겠습니까?',
    ].join('\n'),
  )
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

function StoryLog({ events, emptyLabel = '아직 이벤트가 없습니다.' }: { events: TrpgEvent[]; emptyLabel?: string }) {
  if (events.length === 0) {
    return html`<div class="empty-state" style="font-size:13px">${emptyLabel}</div>`
  }

  return html`
    <div class="trpg-story">
      ${events.map((e: TrpgEvent, i: number) => html`
        <div key=${i} class="trpg-event ${e.type ?? ''}">
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

function TimelinePanel({ events }: { events: TrpgEvent[] }) {
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
  const phaseOptions = Array.from(
    new Set(
      events
        .map(e => (e.phase ?? '').trim())
        .filter(v => v !== ''),
    ),
  ).sort((a, b) => a.localeCompare(b))

  const filteredEvents = events.filter(event => {
    if (actorFilter !== 'all' && eventActorLabel(event) !== actorFilter) return false
    if (typeFilter !== 'all' && (event.type ?? '') !== typeFilter) return false
    if (phaseFilter !== 'all' && (event.phase ?? '') !== phaseFilter) return false
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
          ${typeOptions.map(type => html`<option value=${type}>${type}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${phaseFilter} onChange=${(e: Event) => { timelinePhaseFilter.value = (e.target as HTMLSelectElement).value }}>
          <option value="all">all</option>
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

function SessionOutcome({ outcome }: { outcome?: TrpgState['outcome'] }) {
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

function ControlBox({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const room = trpgRoom.value || state.session?.room || ''
  const status = runStatus.value
  const actors = state.party ?? []
  const selectedActor = actors.find(a => a.id === selectedActorId.value)
  if (!selectedActor && actors.length > 0) {
    const firstActor = actors[0]
    if (firstActor) selectedActorId.value = firstActor.id
  }

  const handleRunRound = async () => {
    if (!room) { showToast('Room ID가 비어 있습니다.', 'error'); return }
    if (!ensureUnlocked(nowMs)) return
    const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
    if (!confirmRiskAction('라운드 실행', room, phase)) return
    runStatus.value = 'running'
    try {
      const result = await runTrpgRound(room)
      lastRoundRun.value = result
      runStatus.value = 'ok'
      const summary = isRecord(result.summary) ? result.summary : null
      const advanced = summary ? recBool(summary, 'advanced', false) : false
      const reason = summary ? recString(summary, 'progress_reason', '') : ''
      showToast(
        advanced ? '라운드가 정상 진행되었습니다.' : `라운드가 정체되었습니다${reason ? `: ${reason}` : ''}`,
        advanced ? 'success' : 'warning',
      )
      refreshTrpg()
    } catch (err) {
      lastRoundRun.value = null
      runStatus.value = 'error'
      const message = err instanceof Error ? err.message : '라운드 실행에 실패했습니다.'
      showToast(message, 'error')
    } finally {
      relockControl()
    }
  }

  const handleAdvanceTurn = async () => {
    if (!room) return
    if (!ensureUnlocked(nowMs)) return
    const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
    if (!confirmRiskAction('턴 강제 진행', room, phase)) return
    try {
      await advanceTrpgTurn(room)
      showToast('턴을 다음 단계로 이동했습니다.', 'success')
      refreshTrpg()
    } catch {
      showToast('턴 이동에 실패했습니다.', 'error')
    } finally {
      relockControl()
    }
  }

  const handleRollDice = async () => {
    if (!room) return
    if (!ensureUnlocked(nowMs)) return
    const actorId = selectedActorId.value.trim()
    if (!actorId) {
      showToast('먼저 Actor를 선택하세요.', 'warning')
      return
    }
    const statValue = Number.parseInt(diceStatValue.value, 10)
    const dc = Number.parseInt(diceDc.value, 10)
    if (Number.isNaN(statValue) || Number.isNaN(dc)) {
      showToast('stat/dc는 숫자여야 합니다.', 'warning')
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
      showToast('주사위 판정을 기록했습니다.', 'success')
      refreshTrpg()
    } catch {
      showToast('주사위 판정 기록에 실패했습니다.', 'error')
    }
  }

  return html`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
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
            <option value="">Actor 선택</option>
            ${actors.map(a => html`<option value=${a.id}>${a.name} (${a.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${diceAction.value}
              onInput=${(e: Event) => { diceAction.value = (e.target as HTMLInputElement).value }}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${diceStatValue.value}
              onInput=${(e: Event) => { diceStatValue.value = (e.target as HTMLInputElement).value }}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${diceDc.value}
              onInput=${(e: Event) => { diceDc.value = (e.target as HTMLInputElement).value }}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
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
              ${status === 'running' ? '실행 중...' : 'Run Round'}
            </button>
            <button class="trpg-run-btn secondary" onClick=${handleAdvanceTurn}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${status !== 'idle'
        ? html`<div class="trpg-run-status ${status}">${status === 'running' ? '처리 중...' : status === 'ok' ? '완료' : '실패'}</div>`
        : null}
    </div>
  `
}

function JoinGatePanel({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const room = trpgRoom.value || state.session?.room || ''
  const gate = state.join_gate
  const eligibilityRaw = joinEligibility.value
  const eligibility = isRecord(eligibilityRaw) ? eligibilityRaw : null

  const checkEligibility = async () => {
    const actorId = joinActorId.value.trim()
    const keeper = joinKeeper.value.trim()
    if (!room || !actorId) {
      showToast('Room/Actor가 필요합니다.', 'warning')
      return
    }
    joinStatus.value = 'checking'
    try {
      const res = await fetchTrpgJoinEligibility(room, actorId, keeper || undefined)
      joinEligibility.value = res as unknown as Record<string, unknown>
      joinStatus.value = 'ok'
      showToast('참가 가능 여부를 갱신했습니다.', 'success')
    } catch (err) {
      joinStatus.value = 'error'
      const message = err instanceof Error ? err.message : '참가 가능 여부 확인에 실패했습니다.'
      showToast(message, 'error')
    }
  }

  const requestMidJoin = async () => {
    const actorId = joinActorId.value.trim()
    const keeper = joinKeeper.value.trim()
    const name = joinActorName.value.trim()
    if (!room || !actorId || !keeper) {
      showToast('Room/Actor/Keeper가 필요합니다.', 'warning')
      return
    }
    if (!ensureUnlocked(nowMs)) return
    const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
    if (!confirmRiskAction('Mid-Join 승인 요청', room, phase)) return
    joinStatus.value = 'requesting'
    try {
      const result = await requestTrpgMidJoin({
        room_id: room,
        actor_id: actorId,
        keeper_name: keeper,
        role: joinRole.value,
        ...(name ? { name } : {}),
      })
      joinEligibility.value = result
      const granted = isRecord(result) ? recBool(result, 'granted', false) : false
      const reasonCode = isRecord(result) ? recString(result, 'reason_code', '') : ''
      if (granted) {
        showToast('Mid-Join이 승인되었습니다.', 'success')
      } else {
        showToast(`Mid-Join이 거절되었습니다${reasonCode ? `: ${reasonCode}` : ''}`, 'warning')
      }
      joinStatus.value = granted ? 'ok' : 'error'
      refreshTrpg()
    } catch (err) {
      joinStatus.value = 'error'
      const message = err instanceof Error ? err.message : 'Mid-Join 요청에 실패했습니다.'
      showToast(message, 'error')
    } finally {
      relockControl()
    }
  }

  return html`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${gate?.phase_open ? 'OPEN' : 'CLOSED'}</strong>
        ${gate?.window ? html`<span style="margin-left:8px;">(${gate.window})</span>` : null}
        <span style="margin-left:8px;">Required: ${gate?.min_points ?? 3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <input
            id="trpg-join-actor-input"
            name="trpg-join-actor-input"
            type="text"
            value=${joinActorId.value}
            onInput=${(e: Event) => { joinActorId.value = (e.target as HTMLInputElement).value }}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${joinKeeper.value}
            onInput=${(e: Event) => { joinKeeper.value = (e.target as HTMLInputElement).value }}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${joinRole.value}
            onChange=${(e: Event) => { joinRole.value = (e.target as HTMLSelectElement).value as 'player' | 'npc' | 'dm' }}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${joinActorName.value}
            onInput=${(e: Event) => { joinActorName.value = (e.target as HTMLInputElement).value }}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${checkEligibility} disabled=${joinStatus.value === 'checking' || joinStatus.value === 'requesting'}>
              ${joinStatus.value === 'checking' ? 'Checking...' : 'Check'}
            </button>
            <button class="trpg-run-btn recommend" onClick=${requestMidJoin} disabled=${joinStatus.value === 'checking' || joinStatus.value === 'requesting'}>
              ${joinStatus.value === 'requesting' ? 'Requesting...' : 'Request Join'}
            </button>
          </div>
        </div>
      </div>
      ${eligibility
        ? html`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${recBool(eligibility, 'eligible', false) ? 'YES' : 'NO'}</strong>
            <span style="margin-left:8px;">Score ${recNumber(eligibility, 'effective_score', 0)}/${recNumber(eligibility, 'required_points', 0)}</span>
            ${recString(eligibility, 'reason_code', '') ? html`<span style="margin-left:8px;">Reason: ${recString(eligibility, 'reason_code', '')}</span>` : null}
          </div>
        `
        : null}
    </div>
  `
}

function ContributionLedger({ state }: { state: TrpgState }) {
  const rows = [...(state.contribution_ledger ?? [])]
    .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
    .slice(0, 8)
  if (rows.length === 0) {
    return html`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`
  }
  return html`
    <div class="trpg-round-list">
      ${rows.map(row => html`
        <div class="trpg-round-item active">
          <span>${row.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${row.score}</span>
          ${row.last_reason
            ? html`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${row.last_reason}</div>`
            : null}
        </div>
      `)}
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

function RoundRunInsight() {
  const result = lastRoundRun.value
  if (!result) {
    return html`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`
  }

  const summaryRaw = result.summary
  const summary = isRecord(summaryRaw) ? summaryRaw : null
  const statusesRaw = Array.isArray(result.statuses) ? result.statuses : []
  const statuses = statusesRaw.filter(isRecord).slice(-8)
  const canonRaw = result.canon_check
  const canon = isRecord(canonRaw) ? canonRaw : null
  const canonWarnings = canon && Array.isArray(canon.warnings)
    ? canon.warnings.filter((w): w is string => typeof w === 'string').slice(0, 3)
    : []
  const canonViolations = canon && Array.isArray(canon.violations)
    ? canon.violations.filter((v): v is string => typeof v === 'string').slice(0, 3)
    : []

  const advanced = summary ? recBool(summary, 'advanced', false) : false
  const progressReason = summary ? recString(summary, 'progress_reason', '') : ''
  const progressDetail = summary ? recString(summary, 'progress_detail', '') : ''
  const playerSuccess = summary ? recNumber(summary, 'player_successes', 0) : 0
  const playerRequired = summary ? recNumber(summary, 'player_required_successes', 0) : 0
  const dmSuccess = summary ? recBool(summary, 'dm_success', false) : false
  const timeouts = summary ? recNumber(summary, 'timeouts', 0) : 0
  const unavailable = summary ? recNumber(summary, 'unavailable', 0) : 0
  const reprompts = summary ? recNumber(summary, 'reprompts', 0) : 0
  const npcAttacks = summary ? recNumber(summary, 'npc_attacks', 0) : 0
  const keeperTimeout = summary ? recNumber(summary, 'keeper_timeout_sec', 0) : 0
  const rollAudit = summary ? recNumber(summary, 'roll_audit_count', 0) : 0

  return html`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${advanced ? 'active' : 'failed'}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${advanced ? 'ADVANCED' : 'STALLED'}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${result.turn_before ?? 0} → ${result.turn_after ?? 0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${dmSuccess ? 'DM ok' : 'DM stalled'} / players ${playerSuccess}/${playerRequired}
          </span>
        </div>
        ${progressReason
          ? html`<div style="margin-top:4px; font-size:12px;">${progressReason}</div>`
          : null}
        ${progressDetail
          ? html`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${progressDetail}</div>`
          : null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${timeouts}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${unavailable}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${reprompts}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${npcAttacks}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${keeperTimeout || 0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${rollAudit}</div></div>
      </div>

      ${statuses.length > 0
        ? html`
          <div class="trpg-round-list">
            ${statuses.map(s => {
              const status = recString(s, 'status', 'unknown')
              const actorId = recString(s, 'actor_id', '-')
              const role = recString(s, 'role', '-')
              const reason = recString(s, 'reason', '')
              const actionType = recString(s, 'action_type', '')
              const reply = recString(s, 'reply', '')
              return html`
                <div class="trpg-round-item ${status.includes('fallback') || status.includes('timeout') ? 'failed' : 'active'}">
                  <span>${actorId} (${role})</span>
                  <span style="margin-left:auto; font-size:11px;">${status}</span>
                  ${actionType ? html`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${actionType}</div>` : null}
                  ${reason ? html`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${reason}</div>` : null}
                  ${reply ? html`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${reply.slice(0, 120)}</div>` : null}
                </div>
              `
            })}
          </div>`
        : null}

      ${canon
        ? html`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${recString(canon, 'status', 'unknown')}</strong>
            </div>
            ${canonViolations.length > 0
              ? html`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${canonViolations.map(v => html`<div>violation: ${v}</div>`)}
                </div>`
              : null}
            ${canonWarnings.length > 0
              ? html`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${canonWarnings.map(w => html`<div>warning: ${w}</div>`)}
                </div>`
              : null}
          </div>
        `
        : null}
    </div>
  `
}

function ControlSafetyPanel({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const room = trpgRoom.value || state.session?.room || ''
  const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
  const locked = isControlLocked(nowMs)
  const remains = controlRemainingSeconds(nowMs)

  return html`
    <${Card} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${locked ? 'locked' : 'unlocked'}">
        <div class="trpg-control-lock-title">
          ${locked ? '잠금 상태: 관전 전용' : '잠금 해제됨'}
        </div>
        <div class="trpg-control-lock-desc">
          ${locked
            ? '조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.'
            : `위험 액션 실행 또는 ${remains}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${room || '-'} · phase: ${phase || '-'}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${locked
            ? html`<button class="trpg-run-btn recommend" onClick=${() => unlockControl(room, phase)}>잠금 해제 (120초)</button>`
            : html`<button class="trpg-run-btn secondary" onClick=${() => { relockControl(); showToast('조작 잠금으로 전환했습니다.', 'success') }}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `
}

function TrpgScreenTabs({ active }: { active: TrpgScreen }) {
  const tabs: Array<{ id: TrpgScreen; label: string; desc: string }> = [
    { id: 'overview', label: 'Overview', desc: '관전 요약' },
    { id: 'timeline', label: 'Timeline', desc: '이벤트 흐름' },
    { id: 'control', label: 'Control', desc: '운영/개입' },
  ]

  return html`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${tabs.map(tab => html`
        <button
          class="trpg-screen-tab ${active === tab.id ? 'active' : ''}"
          role="tab"
          aria-selected=${active === tab.id}
          onClick=${() => setTrpgScreen(tab.id)}
        >
          <span class="trpg-screen-tab-label">${tab.label}</span>
          <span class="trpg-screen-tab-desc">${tab.desc}</span>
        </button>
      `)}
    </div>
  `
}

function OverviewView({ state }: { state: TrpgState }) {
  const party = state.party ?? []
  const events = state.story_log ?? []

  return html`
    <div class="trpg-layout">
      <div>
        <${Card} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${Card} title=${`최근 스토리 (${Math.min(events.length, 20)})`} style="margin-top:16px;">
          <${StoryLog} events=${events.slice(-20)} />
        <//>

        ${state.map
          ? html`
            <${Card} title="맵" style="margin-top:16px;">
              <${AsciiMap} mapStr=${state.map} />
            <//>
          `
          : null}
      </div>

      <div class="trpg-sidebar">
        <${Card} title="현재 라운드">
          <${NextAction} state=${state} />
        <//>

        <${Card} title="기여도" style="margin-top:16px;">
          <${ContributionLedger} state=${state} />
        <//>

        <${Card} title=${`파티 (${party.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${party.map((a: TrpgActor) => html`<${ActorCard} key=${a.id ?? a.name} actor=${a} />`)}
            ${party.length === 0
              ? html`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`
              : null}
          </div>
        <//>

        ${state.history && state.history.length > 0
          ? html`
            <${Card} title=${`히스토리 (${state.history.length})`} style="margin-top:16px;">
              <${RoundHistory} state=${state} />
            <//>
          `
          : null}
      </div>
    </div>
  `
}

function TimelineView({ state }: { state: TrpgState }) {
  const events = state.story_log ?? []

  return html`
    <div class="trpg-layout">
      <div>
        <${Card} title=${`이벤트 타임라인 (${events.length})`}>
          <${TimelinePanel} events=${events} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${Card} title="최근 라운드 결과">
          <${RoundRunInsight} />
        <//>

        <${Card} title="현재 라운드" style="margin-top:16px;">
          <${NextAction} state=${state} />
        <//>
      </div>
    </div>
  `
}

function ControlView({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const party = state.party ?? []

  return html`
    <div>
      <${ControlSafetyPanel} state=${state} nowMs=${nowMs} />
      <div class="trpg-layout">
        <div>
          <${Card} title="조작 패널">
            <${ControlBox} state=${state} nowMs=${nowMs} />
          <//>

          <${Card} title="Mid-Join Gate" style="margin-top:16px;">
            <${JoinGatePanel} state=${state} nowMs=${nowMs} />
          <//>

          <${Card} title="최근 라운드 결과" style="margin-top:16px;">
            <${RoundRunInsight} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${Card} title="기여도" style="margin-top:0;">
            <${ContributionLedger} state=${state} />
          <//>

          <${Card} title=${`파티 (${party.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${party.map((a: TrpgActor) => html`<${ActorCard} key=${a.id ?? a.name} actor=${a} />`)}
              ${party.length === 0
                ? html`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`
                : null}
            </div>
          <//>

          ${state.history && state.history.length > 0
            ? html`
              <${Card} title=${`히스토리 (${state.history.length})`} style="margin-top:16px;">
                <${RoundHistory} state=${state} />
              <//>
            `
            : null}
        </div>
      </div>
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
  const outcome = state.outcome
  const screen = trpgScreen.value
  const nowMs = Date.now()

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

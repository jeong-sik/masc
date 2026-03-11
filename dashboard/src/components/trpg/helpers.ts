// TRPG helpers — Local signals, types, utility functions

import { signal } from '@preact/signals'
import { showToast } from '../common/toast'
// isRecord is used locally by recString/recNumber/recBool below
import { isRecord } from '../common/normalize'
import type { TrpgRoundRunResult } from '../../api'
import type { TrpgEvent } from '../../types'

// ── Local control state ──────────────────────────────────

export const selectedActorId = signal('')
export const diceAction = signal('ability_check')
export const diceStatValue = signal('10')
export const diceDc = signal('12')
export const diceRawD20 = signal('')
export const runStatus = signal<'idle' | 'running' | 'ok' | 'error'>('idle')
export const joinActorId = signal('')
export const joinKeeper = signal('keeper-late')
export const joinRole = signal<'player' | 'npc' | 'dm'>('player')
export const joinActorName = signal('')
export const joinStatus = signal<'idle' | 'checking' | 'requesting' | 'ok' | 'error'>('idle')
export const joinEligibility = signal<Record<string, unknown> | null>(null)
export const spawnActorId = signal('')
export const spawnActorName = signal('')
export const spawnRole = signal<'player' | 'npc' | 'dm'>('player')
export const spawnKeeper = signal('')
export const spawnPortrait = signal('')
export const spawnBackground = signal('')
export const spawnHp = signal('20')
export const spawnMaxHp = signal('20')
export const spawnStatsJson = signal('')
export const spawnStatus = signal<'idle' | 'spawning' | 'ok' | 'error'>('idle')
export const lastRoundRun = signal<TrpgRoundRunResult | null>(null)
export type TrpgScreen = 'overview' | 'timeline' | 'control'
export const trpgScreen = signal<TrpgScreen>('overview')
export const timelineActorFilter = signal('all')
export const timelineTypeFilter = signal('all')
export const timelinePhaseFilter = signal('all')
export const CONTROL_UNLOCK_WINDOW_MS = 120_000
export const controlUnlockUntilMs = signal<number | null>(null)
export const realtimeNowMs = signal(Date.now())

// ── Helpers ──────────────────────────────────────────────

export function hpClass(hp: number, max: number): string {
  const pct = max > 0 ? (hp / max) * 100 : 0
  if (pct > 50) return 'hp-high'
  if (pct > 25) return 'hp-mid'
  return 'hp-low'
}

export function hpPct(hp: number, max: number): number {
  return max > 0 ? Math.round((hp / max) * 100) : 0
}

export const TRAIT_HINTS: Record<string, string> = {
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

export const SKILL_HINTS: Record<string, string> = {
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

export function prettyToken(token: string): string {
  const trimmed = token.trim()
  if (!trimmed) return token
  return trimmed
    .split(/[_-]+/g)
    .filter(part => part.length > 0)
    .map(part => part[0] ? `${part[0].toUpperCase()}${part.slice(1)}` : part)
    .join(' ')
}

export function explainTrait(trait: string): string {
  const key = trait.trim().toLowerCase()
  return TRAIT_HINTS[key] ?? '행동 선택 가중치에 영향을 주는 성향입니다.'
}

export function explainSkill(skill: string): string {
  const key = skill.trim().toLowerCase()
  return SKILL_HINTS[key] ?? '상황에 따라 선택되는 전술 액션입니다.'
}

export { isRecord }

export function recString(obj: Record<string, unknown>, key: string, fallback = ''): string {
  const value = obj[key]
  return typeof value === 'string' ? value : fallback
}

export function recNumber(obj: Record<string, unknown>, key: string, fallback = 0): number {
  const value = obj[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

export function recBool(obj: Record<string, unknown>, key: string, fallback = false): boolean {
  const value = obj[key]
  return typeof value === 'boolean' ? value : fallback
}

export const BASE_STAT_KEYS = new Set(['str', 'dex', 'con', 'int', 'wis', 'cha'])

export function parseSpawnStats(raw: string): Record<string, number> {
  const trimmed = raw.trim()
  if (!trimmed) return {}
  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch (err) {
    throw new Error(`능력치 JSON 파싱 실패: ${err instanceof Error ? err.message : 'invalid json'}`)
  }
  if (!isRecord(parsed)) {
    throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}')
  }
  const stats: Record<string, number> = {}
  Object.entries(parsed).forEach(([key, value]) => {
    const statKey = key.trim()
    if (!statKey) return
    if (typeof value === 'number' && Number.isFinite(value)) {
      stats[statKey] = Math.max(0, Math.trunc(value))
      return
    }
    if (typeof value === 'string') {
      const parsedNumber = Number.parseFloat(value.trim())
      if (Number.isFinite(parsedNumber)) {
        stats[statKey] = Math.max(0, Math.trunc(parsedNumber))
        return
      }
    }
    throw new Error(`능력치 '${statKey}' 값은 숫자여야 합니다.`)
  })
  return stats
}

export function clampSpawnHpToMax(nextMaxRaw: string): void {
  const nextMax = Number.parseInt(nextMaxRaw.trim(), 10)
  if (!Number.isFinite(nextMax)) return
  const normalizedMax = Math.max(1, nextMax)
  const currentHp = Number.parseInt(spawnHp.value.trim(), 10)
  if (Number.isFinite(currentHp) && currentHp > normalizedMax) {
    spawnHp.value = String(normalizedMax)
  }
}

export function eventActorLabel(event: TrpgEvent): string {
  const raw = event.actor_name ?? event.actor ?? event.actor_id ?? 'system'
  const trimmed = raw.trim()
  return trimmed === '' ? 'system' : trimmed
}

export function eventTimeLabel(event: TrpgEvent): string {
  const ts = event.timestamp?.trim() ?? ''
  return ts || '-'
}

export function setTrpgScreen(next: TrpgScreen): void {
  trpgScreen.value = next
}

export function isControlLocked(nowMs: number): boolean {
  const unlockUntil = controlUnlockUntilMs.value
  return unlockUntil == null || unlockUntil <= nowMs
}

export function controlRemainingSeconds(nowMs: number): number {
  const unlockUntil = controlUnlockUntilMs.value
  if (unlockUntil == null || unlockUntil <= nowMs) return 0
  return Math.max(0, Math.ceil((unlockUntil - nowMs) / 1000))
}

export function relockControl(): void {
  controlUnlockUntilMs.value = null
}

export function browserConfirm(message: string): boolean {
  if (typeof window === 'undefined' || typeof window.confirm !== 'function') return true
  return window.confirm(message)
}

export function unlockControl(room: string, phase: string): void {
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

export function ensureUnlocked(nowMs: number): boolean {
  if (isControlLocked(nowMs)) {
    showToast('관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.', 'warning')
    return false
  }
  return true
}

export function confirmRiskAction(actionLabel: string, room: string, phase: string): boolean {
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

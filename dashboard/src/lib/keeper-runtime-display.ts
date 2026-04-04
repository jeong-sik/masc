import type { Keeper } from '../types'
import { relativeTime } from './format-time'

export function keeperDisplayStatus(keeper: Keeper | null | undefined, fallbackStatus?: string | null): string {
  if (keeper?.paused) return 'paused'
  const status = keeper?.status ?? fallbackStatus
  return status && status.trim() !== '' ? status : 'unknown'
}

export function keeperRecentHeartbeatLabel(keeper: Keeper | null | undefined): string {
  return keeper?.last_heartbeat
    ? `최근 하트비트 · ${relativeTime(keeper.last_heartbeat)}`
    : '최근 하트비트 · 기록 없음'
}

export function keeperRecentActionLabel(
  keeper: Keeper | null | undefined,
  fallbackLastTurnAgoS?: number | null,
): string | null {
  if (keeper?.last_autonomous_action_at) {
    return `마지막 행동 · ${relativeTime(keeper.last_autonomous_action_at)}`
  }
  const seconds = keeper?.last_turn_ago_s ?? fallbackLastTurnAgoS
  return typeof seconds === 'number' && Number.isFinite(seconds)
    ? `마지막 턴 · ${Math.round(seconds)}초 전`
    : null
}

export function keeperRuntimeHint(keeper: Keeper | null | undefined): string | null {
  if (!keeper) return null
  const blocker = keeper.last_blocker?.trim()
  if (keeper.paused && blocker) return `일시정지 · ${blocker}`
  if (keeper.paused && keeper.keepalive_running) return '일시정지 · 하트비트만 유지 중'
  if (keeper.paused) return '일시정지됨'
  if (blocker) return `차단 요인 · ${blocker}`
  return null
}

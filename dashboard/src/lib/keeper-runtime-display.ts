import type { Keeper } from '../types'
import { relativeTime } from './format-time'

/** Max seconds since last heartbeat to consider the keeper process alive. */
const HEARTBEAT_ALIVE_THRESHOLD_S = 120

export function keeperDisplayStatus(keeper: Keeper | null | undefined, fallbackStatus?: string | null): string {
  if (keeper?.paused) return 'paused'
  const status = keeper?.status ?? fallbackStatus
  const normalized = (status ?? '').trim().toLowerCase()

  // Refine generic offline/inactive into specific sub-states
  if (normalized === 'offline' || normalized === 'inactive') {
    return refineOfflineStatus(keeper)
  }

  return status && status.trim() !== '' ? status : 'unknown'
}

/** Distinguish "never booted" from "was running but stopped" keepers.
 *  Reconciles heartbeat liveness with agent registration status:
 *  if heartbeat is recent but agent is offline, shows phase instead of "offline". */
function refineOfflineStatus(keeper: Keeper | null | undefined): string {
  if (!keeper) return 'offline'

  // Heartbeat alive but agent offline — keepalive fiber is running.
  // Show actual phase instead of misleading "offline".
  if (keeper.last_heartbeat && isHeartbeatAlive(keeper.last_heartbeat)) {
    const phase = keeper.phase?.trim().toLowerCase()
    if (phase && phase !== 'offline' && phase !== 'inactive') return phase
    return 'idle'
  }

  const generation = keeper.generation ?? 0
  const turnCount = keeper.turn_count ?? 0
  const agentExists = keeper.agent?.exists ?? false

  // Never ran a single turn or generation — registered but never booted
  if (generation === 0 && turnCount === 0 && !agentExists) {
    return 'unbooted'
  }

  // Had activity before but now offline — stopped/crashed
  if (generation > 0 || turnCount > 0) {
    return 'stopped'
  }

  return 'offline'
}

function isHeartbeatAlive(heartbeat: string): boolean {
  const ts = new Date(heartbeat).getTime()
  if (Number.isNaN(ts)) return false
  return (Date.now() - ts) / 1000 < HEARTBEAT_ALIVE_THRESHOLD_S
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

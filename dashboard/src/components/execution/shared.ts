// Execution panel shared pure functions

import type { DashboardExecutionContinuityBrief } from '../../types'

const TERMINAL_STATUSES = new Set(['completed', 'interrupted', 'failed', 'cancelled'])

export function isTerminalStatus(status: string | null | undefined): boolean {
  if (status == null) return false
  return TERMINAL_STATUSES.has(status.trim().toLowerCase())
}

export function partitionByTerminal<T>(
  items: T[],
  getStatus: (item: T) => string | null | undefined,
): [T[], T[]] {
  const active: T[] = []
  const terminal: T[] = []
  for (const item of items) {
    if (isTerminalStatus(getStatus(item))) {
      terminal.push(item)
    } else {
      active.push(item)
    }
  }
  return [active, terminal]
}

export function queueKindLabel(kind: string): string {
  if (kind === 'session') return '세션'
  if (kind === 'operation') return '작전'
  return kind
}

export function keeperFromBrief(brief: DashboardExecutionContinuityBrief): {
  name: string
  agent_name: string
  status: string
  emoji: string
} {
  return {
    name: brief.name,
    agent_name: brief.agent_name?.trim() || brief.name,
    status: brief.status ?? 'unknown',
    emoji: brief.emoji ?? '',
  }
}

export function agentStateLabel(state: string): string {
  if (state === 'working') return '작업 중'
  if (state === 'watching') return '대기 중'
  if (state === 'quiet') return '조용함'
  if (state === 'offline') return '오프라인'
  return state
}

export function signalTruthLabel(truth: string | null | undefined): string {
  if (truth == null) return 'signal 미상'
  if (truth === 'live') return '최근 신호(≤5m)'
  if (truth === 'stale') return '오래된 신호(>5m)'
  if (truth === 'absent') return 'signal 없음'
  return truth
}

export function evidenceSourceLabel(source: string | null | undefined): string {
  if (source == null) return '근거 미상'
  if (source === 'message') return '최근 출력'
  if (source === 'presence') return 'presence/하트비트'
  if (source === 'none') return '근거 없음'
  return source
}

export function continuityStateLabel(state: string): string {
  if (state === 'critical') return '위험'
  if (state === 'warning') return '주의'
  return '정상'
}

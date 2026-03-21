import { prettyJson, displayStatus, statusLabel } from '../../lib/status-label'
import type {
  OperatorAttentionItem,
  OperatorGuidanceSummary,
  OperatorKeeperSnapshot,
  OperatorResidentJudgeRuntime,
  OperatorSessionSnapshot,
} from '../../types'
import type { OpsTeamTurnKind } from './ops-state'

export { prettyJson, displayStatus }

export type OpsPriorityTone = 'ok' | 'warn' | 'bad'

export interface OpsPriorityCardData {
  key: string
  label: string
  value: string | number
  detail: string
  tone: OpsPriorityTone
}

export function guidanceLayerLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'judgment':
      return '상주 판단'
    case 'fallback':
      return '보조 읽기 모델'
    default:
      return value?.trim() || '안내'
  }
}

export function guidanceLayerTone(value?: string | null): OpsPriorityTone {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'judgment':
      return 'ok'
    case 'fallback':
      return 'warn'
    default:
      return 'warn'
  }
}

export function runtimeJudgeLabel(runtime?: OperatorResidentJudgeRuntime | null): string {
  if (!runtime?.enabled) return '꺼짐'
  if (runtime.refreshing) return '갱신 중'
  if (runtime.judge_online) return '온라인'
  return runtime.last_error ? '오류' : '대기'
}

export function runtimeJudgeTone(runtime?: OperatorResidentJudgeRuntime | null): OpsPriorityTone {
  if (!runtime?.enabled) return 'warn'
  if (runtime.judge_online) return 'ok'
  if (runtime.refreshing) return 'warn'
  return 'bad'
}

export function guidanceFreshnessLabel(summary?: OperatorGuidanceSummary | null): string {
  if (!summary?.fresh_until) return '갱신 기준 없음'
  return summary.fresh_until
}

export function relativeAge(seconds?: number): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return '확인 없음'
  if (seconds < 60) return `${Math.round(seconds)}초 전`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분 전`
  return `${Math.round(seconds / 3600)}시간 전`
}

export function normalizeStatus(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

export function isSessionTerminal(session: OperatorSessionSnapshot): boolean {
  const status = normalizeStatus(session.status)
  return status === 'done'
    || status === 'completed'
    || status === 'ended'
    || status === 'cancelled'
    || status === 'stopped'
    || status === 'failed'
    || status === 'error'
    || status === 'interrupted'
}

export function pickPreferredSession(
  sessions: OperatorSessionSnapshot[],
): OperatorSessionSnapshot | null {
  return sessions.find(session => !isSessionTerminal(session)) ?? sessions[0] ?? null
}

export function sessionHealthLabel(session: OperatorSessionSnapshot): string {
  const health = normalizeStatus(session.team_health?.status)
  return health ? statusLabel(health) : '상태 확인 필요'
}

export function sessionOutcomeLabel(session: OperatorSessionSnapshot): string {
  return `${session.done_delta_total ?? 0}건 완료`
}

export function sessionPriorityTone(session: OperatorSessionSnapshot): OpsPriorityTone {
  const status = normalizeStatus(session.status)
  if (status === 'paused') return 'bad'
  if (status === '' || status === 'unknown') return 'warn'
  const health = normalizeStatus(session.team_health?.status)
  if (health && health !== 'ok' && health !== 'healthy' && health !== 'green') return 'warn'
  if (status && status !== 'active' && status !== 'running' && status !== 'ended') return 'warn'
  return 'ok'
}

export function keeperPriorityTone(keeper: OperatorKeeperSnapshot): OpsPriorityTone {
  const status = normalizeStatus(keeper.status)
  if (status === 'offline' || status === 'inactive' || status === 'error') return 'bad'
  if (status === '' || status === 'unknown') return 'warn'
  if ((keeper.context_ratio ?? 0) >= 0.8) return 'warn'
  if (keeper.context_ratio == null) return 'warn'
  if (keeper.last_turn_ago_s == null) return 'warn'
  if ((keeper.last_turn_ago_s ?? 0) >= 3600) return 'warn'
  return 'ok'
}

export function attentionTone(items: OperatorAttentionItem[]): OpsPriorityTone {
  if (items.some(item => normalizeStatus(item.severity) === 'bad')) return 'bad'
  if (items.length > 0) return 'warn'
  return 'ok'
}

export function isSessionAttention(item: OperatorAttentionItem): boolean {
  return item.target_type === 'team_session'
}

export function isKeeperAttention(item: OperatorAttentionItem): boolean {
  return item.target_type === 'keeper'
}

export function actionTypeLabel(value?: string | null): string {
  switch (value) {
    case 'broadcast':
      return '방송'
    case 'room_pause':
      return '방 일시정지'
    case 'room_resume':
      return '방 재개'
    case 'team_turn':
      return '세션 업데이트'
    case 'team_note':
      return '세션 노트'
    case 'team_broadcast':
      return '세션 방송'
    case 'team_task_inject':
      return '세션 작업 주입'
    case 'team_worker_spawn_batch':
      return '세션 작업자 교체'
    case 'task_inject':
      return '작업 주입'
    case 'team_stop':
      return '세션 중지'
    case 'keeper_message':
      return '키퍼 메시지'
    case 'keeper_msg':
      return '키퍼 메시지'
    default:
      return value?.trim() || '액션'
  }
}

export function targetTypeLabel(value?: string | null): string {
  switch (value) {
    case 'room':
      return '방'
    case 'team_session':
      return '세션'
    case 'keeper':
      return '키퍼'
    case 'swarm_run':
      return '스웜 실행'
    default:
      return value?.trim() || '대상'
  }
}

export function deliveryModeLabel(confirmRequired?: boolean): string {
  return confirmRequired ? '확인 후 실행' : '즉시 실행'
}

export function sessionActionLabel(value: OpsTeamTurnKind): string {
  switch (value) {
    case 'note':
      return '노트'
    case 'broadcast':
      return '방송'
    case 'task':
      return '작업'
    case 'worker_spawn_batch':
      return '작업자 교체'
    default:
      return value
  }
}

export function formatMessageContent(content: string): string {
  if (!content) return ''
  return content
    .replace(/\[team-session:ts-\d+-\w+\.\.\./g, '[session ')
    .replace(/\[team-session:([^\]]{0,20})[^\]]*\]/g, '[session $1]')
    .replace(/ts-\d{13,}-[a-f0-9]{4,8}/g, (match) => {
      const ts = match.match(/ts-(\d{13,})/)
      const tsValue = ts?.[1]
      if (tsValue) {
        const date = new Date(parseInt(tsValue, 10))
        return date.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
      }
      return match
    })
}

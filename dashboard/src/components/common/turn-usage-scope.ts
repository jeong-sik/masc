import type { TurnRecordEntry } from '../../api/dashboard-turn-records'

export const USAGE_SCOPE_LABELS: Record<TurnRecordEntry['usage_scope'], string> = {
  per_request: '요청별',
  turn_total: '클라이언트 턴 합계',
  conversation_cumulative: '대화 누적',
  unavailable: '범위 미상',
}

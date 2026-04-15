// Unified status display utilities.
// Consolidates statusLabel, displayStatus, prettyJson from
// mission-utils, agents, agent-roster, status-badge, helpers, ops/helpers.

/** Comprehensive status label — maps normalized status strings to Korean labels. */
export function statusLabel(value?: string | null): string {
  const normalized = (value ?? '').trim().toLowerCase()
  switch (normalized) {
    case 'ok':
    case 'healthy':
    case 'green':
      return '안정'
    case 'active':
    case 'running':
      return '진행 중'
    case 'working':
    case 'busy':
      return '작업 중'
    case 'watching':
      return '관찰 중'
    case 'listening':
      return '대기'
    case 'pending':
      return '대기 중'
    case 'paused':
      return '일시정지'
    case 'blocked':
      return '차단됨'
    case 'interrupted':
      return '중단됨'
    case 'warn':
    case 'watch':
    case 'warning':
    case 'degraded':
      return '주의'
    case 'bad':
    case 'critical':
    case 'risk':
      return '위험'
    case 'offline':
    case 'inactive':
      return '오프라인'
    case 'unbooted':
      return '미기동'
    case 'stopped':
      return '중단됨'
    case 'idle':
      return '대기'
    case 'quiet':
      return '조용함'
    case 'loading':
      return '불러오는 중'
    case 'error':
    case 'failed':
      return '오류'
    case 'unavailable':
      return '사용 불가'
    case 'stale':
      return '오래됨'
    case 'refreshing':
      return '갱신 중'
    case 'cached':
      return '캐시됨'
    case 'connected':
      return '연결됨'
    case 'disconnected':
      return '끊김'
    case 'ready':
      return '준비됨'
    case 'done':
    case 'completed':
    case 'ended':
      return '완료'
    case 'cancelled':
      return '취소됨'
    case 'retired':
      return '은퇴'
    case 'spawned':
      return '생성됨'
    case 'compacting':
      return '컴팩팅'
    case 'handoff':
      return '핸드오프'
    case 'claimed':
      return '점유됨'
    case 'in_progress':
      return '진행 중'
    case 'todo':
      return '대기'
    case 'preview':
      return '미리보기'
    case 'captured':
      return '기록됨'
    case 'unknown':
    case '':
      return '확인 필요'
    default:
      return value?.trim() || '확인 필요'
  }
}

/** Short display status — fewer cases, used in operator contexts. */
export function displayStatus(status?: string | null): string {
  const normalized = (status ?? '').trim().toLowerCase()
  if (!normalized) return '확인 필요'
  if (normalized === 'active' || normalized === 'running') return '진행 중'
  if (normalized === 'paused') return '일시정지'
  if (normalized === 'done' || normalized === 'ended' || normalized === 'completed') return '완료'
  if (normalized === 'failed' || normalized === 'error') return '문제'
  if (normalized === 'stopped') return '중단됨'
  if (normalized === 'unbooted') return '미기동'
  if (normalized === 'offline') return '오프라인'
  if (normalized === 'idle') return '대기'
  if (normalized === 'unknown') return '확인 필요'
  return status?.trim() || '확인 필요'
}

/** Format unknown values as pretty JSON or pass-through strings. */
export function prettyJson(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

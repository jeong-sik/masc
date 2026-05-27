import { UNKNOWN_STATUS_LABEL } from './format-string'

// Unified status display utilities.
// Consolidates statusLabel from
// mission-utils, agents, agent-roster, status-badge, helpers, ops/helpers.
//
// SSOT principle: one English-key → one Korean label. Sister keys that share
// a meaning (e.g. `done`/`completed`/`ended`) collapse to the same label.
// Distinct meanings get distinct labels — collisions across unrelated keys
// (the prior `중단됨` = interrupted + stopped, `대기` = listening + idle + todo,
// `오류` vs `문제` for error/failed) are an operator-confusion source.

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
    case 'in_progress':
      return '진행 중'
    case 'working':
    case 'busy':
      return '작업 중'
    case 'watching':
      return '관찰 중'
    case 'listening':
      return '수신 대기'
    case 'pending':
      return '대기 중'
    case 'todo':
      return '예정'
    case 'idle':
      return '대기'
    case 'paused':
      return '일시정지'
    case 'blocked':
      return '차단됨'
    case 'interrupted':
      return '인터럽트됨'
    case 'stopped':
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
    case 'awaiting_verification':
      return '검증 대기'
    case 'preview':
      return '미리보기'
    case 'captured':
      return '기록됨'
    case 'unknown':
    case '':
      return UNKNOWN_STATUS_LABEL
    default:
      return value?.trim() || UNKNOWN_STATUS_LABEL
  }
}

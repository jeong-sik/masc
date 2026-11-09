import type { GoalCriterionReviewProjection } from '../types/goal-criterion-review'
import { isRecord } from '../components/common/normalize'

function text(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== ''
}

/** A failed observation cannot become an unchecked or viable criterion. */
export function decodeGoalCriterionReview(
  raw: unknown,
  criterionRevision: string,
): GoalCriterionReviewProjection {
  const unavailable = (detail: string): GoalCriterionReviewProjection => ({ state: 'unavailable', detail })
  if (!isRecord(raw)) return unavailable('기준 검토 관측이 응답에 없습니다.')
  if (raw.state === 'unchecked') return { state: 'unchecked' }
  if (raw.state === 'unavailable') {
    return unavailable(text(raw.detail) ? raw.detail : '기준 검토 저장소의 오류 사유를 읽지 못했습니다.')
  }
  switch (raw.state) {
    case 'pending':
    case 'execution_pending':
    case 'execution_unknown':
    case 'judgment_pending':
    case 'deferred':
    case 'superseded':
    case 'viable':
    case 'needs_revision': {
      if (!text(raw.request_id) || !text(raw.criterion_revision)
        || raw.criterion_revision !== criterionRevision
        || (raw.detail !== null && !text(raw.detail))) {
        return unavailable('기준 검토의 요청 또는 현재 기준 revision을 확인하지 못했습니다.')
      }
      const binding = {
        request_id: raw.request_id,
        criterion_revision: raw.criterion_revision,
        detail: raw.detail,
      }
      if (raw.state === 'viable' || raw.state === 'needs_revision') {
        if (!text(raw.reason)) return unavailable('기준 검토의 판정 이유가 없습니다.')
        return { ...binding, state: raw.state, reason: raw.reason }
      }
      if (raw.reason !== null) return unavailable('진행 중인 기준 검토가 판정 이유를 담고 있습니다.')
      return { ...binding, state: raw.state, reason: null }
    }
    default:
      return unavailable(`알 수 없는 기준 검토 상태: ${String(raw.state)}`)
  }
}

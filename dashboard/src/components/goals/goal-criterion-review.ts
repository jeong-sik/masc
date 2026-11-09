import { html } from 'htm/preact'
import type { GoalCriterionReviewProjection } from '../../types/goal-criterion-review'

function label(review: GoalCriterionReviewProjection): string {
  switch (review.state) {
    case 'unchecked': return '기준 검토 미기록'
    case 'unavailable': return '기준 검토 확인 불가'
    case 'pending': return '기준 검토 대기'
    case 'execution_pending': return '기준 검토 실행 중'
    case 'execution_unknown': return '기준 검토 실행 결과 불확실'
    case 'judgment_pending': return '기준 판정 반영 대기'
    case 'deferred': return '기준 검토 보류'
    case 'viable': return '도달 가능한 기준'
    case 'needs_revision': return '기준 수정 필요'
    case 'superseded': return '기준 검토 대체됨'
    default: {
      const unhandled: never = review
      return unhandled
    }
  }
}

const missing: GoalCriterionReviewProjection = {
  state: 'unavailable', detail: '현재 목표의 기준 검토 관측을 읽지 못했습니다.',
}

export function GoalCriterionReviewStatus({ review = missing }: { review?: GoalCriterionReviewProjection }) {
  return html`<span data-goal-criterion-review=${review.state}>${label(review)}</span>`
}

export function GoalCriterionReviewDetail({ review = missing }: { review?: GoalCriterionReviewProjection }) {
  const bound = review.state !== 'unchecked' && review.state !== 'unavailable' ? review : null
  const detail = review.state === 'unavailable' ? review.detail
    : bound?.state === 'viable' || bound?.state === 'needs_revision' ? bound.reason : bound?.detail
  return html`
    <section aria-label="Goal 성공 기준 검토" class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-surface)] p-4 text-sm text-text-body">
      <${GoalCriterionReviewStatus} review=${review} />
      ${detail ? html`<p class="mt-2 whitespace-pre-wrap break-words" data-criterion-review-detail>${detail}</p>` : null}
      ${bound ? html`<dl class="mt-2 break-all text-xs text-text-muted">
        <dt>기준 revision</dt><dd>${bound.criterion_revision}</dd>
        <dt>검토 요청</dt><dd>${bound.request_id}</dd>
      </dl>` : null}
      <p class="mt-2 text-xs text-text-muted">성공 기준의 실재성과 도달 가능성에 대한 검토입니다. 완료 증명과 사람의 최종 확인은 별도로 진행합니다.</p>
    </section>
  `
}

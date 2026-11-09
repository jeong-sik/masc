import { html } from 'htm/preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { decodeGoalCriterionReview } from '../../api/goal-criterion-review'
import { GoalCriterionReviewDetail } from './goal-criterion-review'

afterEach(cleanup)

describe('Goal criterion review consumer', () => {
  it('shows the received judgment and binding, then replaces it when execution is uncertain', () => {
    const received = decodeGoalCriterionReview({ state: 'viable', criterion_revision: 'criterion-7',
      request_id: 'request-8', reason: '<source> can be measured', detail: null }, 'criterion-7')
    const view = render(html`<${GoalCriterionReviewDetail} review=${received} />`)
    expect(view.container.querySelector('[data-goal-criterion-review]')?.getAttribute('data-goal-criterion-review')).toBe('viable')
    expect(screen.getByText('<source> can be measured')).toBeTruthy()
    expect(screen.getByText('criterion-7')).toBeTruthy()
    expect(screen.getByText('request-8')).toBeTruthy()
    const uncertain = decodeGoalCriterionReview({ state: 'execution_unknown', criterion_revision: 'criterion-7',
      request_id: 'request-9', reason: null, detail: 'provider receipt is unavailable' }, 'criterion-7')
    view.rerender(html`<${GoalCriterionReviewDetail} review=${uncertain} />`)
    expect(view.container.querySelector('[data-goal-criterion-review]')?.getAttribute('data-goal-criterion-review')).toBe('execution_unknown')
    expect(screen.queryByText('<source> can be measured')).toBeNull()
    expect(screen.queryByText('request-8')).toBeNull()
    expect(screen.getByText('provider receipt is unavailable')).toBeTruthy()
    expect(screen.getByText('request-9')).toBeTruthy()
  })

  it('shows an unavailable observation instead of a previous criterion judgment', () => {
    const review = decodeGoalCriterionReview({ state: 'needs_revision', criterion_revision: 'old',
      request_id: 'old-request', reason: 'old reason', detail: null }, 'current')
    const view = render(html`<${GoalCriterionReviewDetail} review=${review} />`)
    expect(view.container.querySelector('[data-goal-criterion-review]')?.getAttribute('data-goal-criterion-review')).toBe('unavailable')
    expect(screen.queryByText('old reason')).toBeNull()
    expect(screen.queryByText('old-request')).toBeNull()
  })
})

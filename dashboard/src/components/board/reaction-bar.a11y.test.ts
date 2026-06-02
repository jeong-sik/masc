// @vitest-environment happy-dom
import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { axe } from 'jest-axe'
import '@testing-library/jest-dom'

vi.mock('../../api/board', () => ({
  fetchBoardReactions: vi.fn().mockResolvedValue([]),
  toggleReaction: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

import { toggleReaction } from '../../api/board'
import { ReactionBar } from './reaction-bar'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ReactionBar a11y', () => {
  it('renders embedded summaries without axe violations', async () => {
    const { container } = render(h(ReactionBar, {
      targetType: 'post',
      targetId: 'post-1',
      initialSummaries: [{
        emoji: '🔥',
        count: 2,
        reacted: true,
        has_reacted: true,
        recent_user_ids: ['agent-a'],
      }],
    }))

    expect(await axe(container)).toHaveNoViolations()
  })

  it('keeps the failed-toggle live status axe clean', async () => {
    vi.mocked(toggleReaction).mockRejectedValueOnce(new Error('network down'))

    const { container } = render(h(ReactionBar, {
      targetType: 'post',
      targetId: 'post-1',
      initialSummaries: [],
    }))

    fireEvent.click(screen.getByRole('button', { name: '👍 리액션 0개' }))

    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent('리액션 반영에 실패했습니다')
    })
    expect(await axe(container)).toHaveNoViolations()
  })
})

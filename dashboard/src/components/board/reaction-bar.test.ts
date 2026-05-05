import { h } from 'preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

vi.mock('../../api/board', () => ({
  fetchBoardReactions: vi.fn().mockResolvedValue([]),
  toggleReaction: vi.fn(),
}))

import { fetchBoardReactions } from '../../api/board'
import { lastEvent } from '../../sse'
import { ReactionBar } from './reaction-bar'

afterEach(() => {
  cleanup()
  lastEvent.value = null
  vi.clearAllMocks()
})

describe('ReactionBar', () => {
  it('renders the eight standard board reactions', () => {
    render(h(ReactionBar, { targetType: 'post', targetId: 'post-1' }))

    for (const emoji of ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥']) {
      expect(screen.getByRole('button', { name: `${emoji} 리액션 0개` })).toBeInTheDocument()
    }
  })

  it('refreshes summaries only when a matching reaction_changed event arrives', async () => {
    vi.mocked(fetchBoardReactions)
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([{
        emoji: '🔥',
        count: 3,
        reacted: false,
        has_reacted: false,
        recent_user_ids: ['agent-a', 'agent-b'],
      }])

    render(h(ReactionBar, { targetType: 'post', targetId: 'post-1' }))

    await waitFor(() => {
      expect(fetchBoardReactions).toHaveBeenCalledTimes(1)
    })

    lastEvent.value = {
      type: 'reaction_changed',
      target_type: 'post',
      target_id: 'other-post',
      user_id: 'agent-a',
      emoji: '🔥',
      reacted: true,
    }
    await Promise.resolve()
    expect(fetchBoardReactions).toHaveBeenCalledTimes(1)

    lastEvent.value = {
      type: 'reaction_changed',
      target_type: 'post',
      target_id: 'post-1',
      user_id: 'agent-a',
      emoji: '🔥',
      reacted: true,
    }

    await waitFor(() => {
      expect(fetchBoardReactions).toHaveBeenCalledTimes(2)
      expect(screen.getByRole('button', { name: '🔥 리액션 3개' })).toBeInTheDocument()
    })
  })
})

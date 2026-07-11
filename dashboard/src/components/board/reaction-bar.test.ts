import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

vi.mock('../../api/board', () => ({
  fetchBoardReactionState: vi.fn().mockResolvedValue({
    summaries: [],
    supportedEmojis: ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥'],
  }),
  toggleReaction: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

import { fetchBoardReactionState, toggleReaction } from '../../api/board'
import { lastEvent } from '../../sse'
import { showToast } from '../common/toast'
import { ReactionBar } from './reaction-bar'

afterEach(() => {
  cleanup()
  lastEvent.value = null
  vi.clearAllMocks()
})

describe('ReactionBar', () => {
  it('renders the reaction catalog returned by the server', async () => {
    render(h(ReactionBar, { targetType: 'post', targetId: 'post-1' }))

    await waitFor(() => {
      for (const emoji of ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥']) {
        expect(screen.getByRole('button', { name: `${emoji} 리액션 0개` })).toBeInTheDocument()
      }
      expect(screen.getByRole('status')).toHaveTextContent('')
    })
  })

  it('uses embedded initial summaries without an initial fetch', async () => {
    render(h(ReactionBar, {
      targetType: 'post',
      targetId: 'post-1',
      initialSummaries: [{
        emoji: '👏',
        count: 5,
        reacted: true,
        has_reacted: true,
        recent_user_ids: ['agent-a'],
      }],
      supportedEmojis: ['👏'],
    }))

    expect(screen.getByRole('button', { name: '👏 리액션 5개' })).toHaveAttribute('aria-pressed', 'true')
    await Promise.resolve()
    expect(fetchBoardReactionState).not.toHaveBeenCalled()
  })

  it('refreshes summaries only when a matching reaction_changed event arrives', async () => {
    vi.mocked(fetchBoardReactionState)
      .mockResolvedValueOnce({ summaries: [], supportedEmojis: ['🔥'] })
      .mockResolvedValueOnce({
        summaries: [{
          emoji: '🔥',
          count: 3,
          reacted: false,
          has_reacted: false,
          recent_user_ids: ['agent-a', 'agent-b'],
        }],
        supportedEmojis: ['🔥'],
      })

    render(h(ReactionBar, { targetType: 'post', targetId: 'post-1' }))

    await waitFor(() => {
      expect(fetchBoardReactionState).toHaveBeenCalledTimes(1)
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
    expect(fetchBoardReactionState).toHaveBeenCalledTimes(1)

    lastEvent.value = {
      type: 'reaction_changed',
      target_type: 'post',
      target_id: 'post-1',
      user_id: 'agent-a',
      emoji: '🔥',
      reacted: true,
    }

    await waitFor(() => {
      expect(fetchBoardReactionState).toHaveBeenCalledTimes(2)
      expect(screen.getByRole('button', { name: '🔥 리액션 3개' })).toBeInTheDocument()
    })
  })

  it('clears the live status before retrying reaction summary refreshes', async () => {
    vi.mocked(fetchBoardReactionState).mockRejectedValueOnce(new Error('offline'))

    render(h(ReactionBar, { targetType: 'post', targetId: 'post-1' }))

    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent('리액션 요약을 불러오지 못했습니다')
    })

    let resolveRefresh: (value: { summaries: []; supportedEmojis: string[] }) => void = () => {}
    vi.mocked(fetchBoardReactionState).mockImplementationOnce(() => new Promise(resolve => {
      resolveRefresh = resolve
    }))

    lastEvent.value = {
      type: 'reaction_changed',
      target_type: 'post',
      target_id: 'post-1',
      user_id: 'agent-a',
      emoji: '🔥',
      reacted: true,
    }

    await waitFor(() => {
      expect(fetchBoardReactionState).toHaveBeenCalledTimes(2)
      expect(screen.getByRole('status')).toHaveTextContent('리액션 종류를 불러오는 중입니다')
    })
    resolveRefresh({ summaries: [], supportedEmojis: ['🔥'] })
    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent(/^$/)
    })
  })

  it('applies a successful click result to the visible reaction state', async () => {
    vi.mocked(toggleReaction).mockResolvedValueOnce({
      target_type: 'post',
      target_id: 'post-1',
      user_id: 'dashboard-reviewer',
      emoji: '👍',
      reacted: true,
      summary: [{
        emoji: '👍',
        count: 1,
        reacted: true,
        has_reacted: true,
        recent_user_ids: ['dashboard-reviewer'],
      }],
    })

    render(h(ReactionBar, {
      targetType: 'post',
      targetId: 'post-1',
      initialSummaries: [],
      supportedEmojis: ['👍'],
    }))

    fireEvent.click(screen.getByRole('button', { name: '👍 리액션 0개' }))

    const reacted = await screen.findByRole('button', { name: '👍 리액션 1개' })
    expect(reacted).toHaveAttribute('aria-pressed', 'true')
    expect(toggleReaction).toHaveBeenCalledWith('post', 'post-1', '👍')
  })

  it('announces and toasts failed reaction toggles', async () => {
    vi.mocked(toggleReaction).mockRejectedValueOnce(new Error('network down'))

    render(h(ReactionBar, { targetType: 'post', targetId: 'post-1' }))

    const reaction = await screen.findByRole('button', { name: '👍 리액션 0개' })
    fireEvent.click(reaction)

    await waitFor(() => {
      expect(toggleReaction).toHaveBeenCalledWith('post', 'post-1', '👍')
      expect(showToast).toHaveBeenCalledWith('리액션 반영에 실패했습니다', 'error')
    })
    expect(screen.getByRole('status')).toHaveTextContent('리액션 반영에 실패했습니다')
    expect(reaction).not.toBeDisabled()
  })
})

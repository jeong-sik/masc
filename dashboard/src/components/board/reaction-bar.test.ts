import { h } from 'preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
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
import { ReactionBar, type ReactionBatchObservation } from './reaction-bar'

function orderedBatch(revision: number, count = 0): ReactionBatchObservation {
  return {
    state: 'ready', revision, supportedEmojis: ['👍'],
    byTargetId: new Map([['ordered-row', [{ emoji: '👍', count, reacted: count > 0, recent_user_ids: [] }]]]),
  }
}

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
      expect(screen.getByRole('status')).toHaveTextContent('불러오는 중…')
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
    expect(reaction).toBeDisabled()
    expect(reaction).not.toHaveAttribute('aria-pressed')
    fireEvent.click(reaction)
    expect(toggleReaction).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: '리액션 다시 확인' }))
    await waitFor(() => {
      expect(screen.getByRole('button', { name: '👍 리액션 0개' })).not.toBeDisabled()
    })
    expect(toggleReaction).toHaveBeenCalledTimes(1)
  })

  it('keeps an unavailable summary distinct from a known empty selection', async () => {
    vi.mocked(fetchBoardReactionState).mockRejectedValueOnce(new Error('source unavailable'))
    render(h(ReactionBar, {
      targetType: 'post', targetId: 'unknown-source', supportedEmojis: ['🔥'],
    }))

    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('불러오지 못했습니다'))
    const reaction = screen.getByRole('button', { name: '🔥 리액션 확인 불가' })
    expect(reaction).toBeDisabled()
    expect(reaction).not.toHaveAttribute('aria-pressed')
    fireEvent.click(reaction)
    expect(toggleReaction).not.toHaveBeenCalled()
  })

  it('retains the last count as display after a failed refresh without authorizing a toggle', async () => {
    vi.mocked(fetchBoardReactionState).mockRejectedValueOnce(new Error('source unavailable'))
    render(h(ReactionBar, {
      targetType: 'post', targetId: 'post-stale', supportedEmojis: ['🔥'],
      initialSummaries: [{ emoji: '🔥', count: 3, reacted: true, recent_user_ids: ['agent-a'] }],
    }))
    lastEvent.value = {
      type: 'reaction_changed', target_type: 'post', target_id: 'post-stale',
      user_id: 'agent-b', emoji: '🔥', reacted: true,
    }

    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('불러오지 못했습니다'))
    const reaction = screen.getByRole('button', { name: '🔥 리액션 확인 불가' })
    expect(reaction).toHaveTextContent('3')
    expect(reaction).toBeDisabled()
    expect(reaction).not.toHaveAttribute('aria-pressed')
    fireEvent.click(reaction)
    expect(toggleReaction).not.toHaveBeenCalled()
  })

  it('does not publish an earlier target toggle result into the current target', async () => {
    let finishToggle: (value: Awaited<ReturnType<typeof toggleReaction>>) => void = () => {}
    vi.mocked(toggleReaction).mockImplementationOnce(() => new Promise(resolve => { finishToggle = resolve }))
    const view = render(h(ReactionBar, {
      targetType: 'post', targetId: 'old-target', initialSummaries: [], supportedEmojis: ['👍'],
    }))
    fireEvent.click(screen.getByRole('button', { name: '👍 리액션 0개' }))
    view.rerender(h(ReactionBar, {
      targetType: 'post', targetId: 'new-target', initialSummaries: [], supportedEmojis: ['👍'],
    }))
    await act(async () => {
      finishToggle({
        target_type: 'post', target_id: 'old-target', user_id: 'dashboard-reviewer', emoji: '👍',
        reacted: true, summary: [{ emoji: '👍', count: 1, reacted: true, recent_user_ids: ['dashboard-reviewer'] }],
      })
    })

    await waitFor(() => expect(screen.getByRole('button', { name: '👍 리액션 0개' })).toHaveAttribute('aria-pressed', 'false'))
    expect(screen.queryByRole('button', { name: '👍 리액션 1개' })).not.toBeInTheDocument()
    expect(toggleReaction).toHaveBeenCalledTimes(1)
  })

  it('refreshes a matching invalidation received while a toggle is pending', async () => {
    let finishToggle: (value: Awaited<ReturnType<typeof toggleReaction>>) => void = () => {}
    vi.mocked(toggleReaction).mockImplementationOnce(() => new Promise(resolve => { finishToggle = resolve }))
    vi.mocked(fetchBoardReactionState).mockResolvedValueOnce({
      summaries: [{ emoji: '👍', count: 2, reacted: true, recent_user_ids: ['other', 'viewer'] }],
      supportedEmojis: ['👍'],
    })
    render(h(ReactionBar, {
      targetType: 'post', targetId: 'pending-invalidation', initialSummaries: [], supportedEmojis: ['👍'],
    }))
    fireEvent.click(screen.getByRole('button', { name: '👍 리액션 0개' }))
    lastEvent.value = {
      type: 'reaction_changed', target_type: 'post', target_id: 'pending-invalidation',
      user_id: 'other', emoji: '👍', reacted: true,
    }
    expect(fetchBoardReactionState).not.toHaveBeenCalled()
    await act(async () => {
      finishToggle({
        target_type: 'post', target_id: 'pending-invalidation', user_id: 'viewer', emoji: '👍', reacted: true,
        summary: [{ emoji: '👍', count: 1, reacted: true, recent_user_ids: ['viewer'] }],
      })
    })

    expect(await screen.findByRole('button', { name: '👍 리액션 2개' })).toHaveAttribute('aria-pressed', 'true')
    expect(fetchBoardReactionState).toHaveBeenCalledTimes(1)
    expect(toggleReaction).toHaveBeenCalledTimes(1)
  })

  it.each(['success', 'failure'] as const)('fences an unseen batch start when a toggle settles with %s', async outcome => {
    let finishToggle!: (value: Awaited<ReturnType<typeof toggleReaction>>) => void
    let failToggle!: (error: Error) => void
    vi.mocked(toggleReaction).mockImplementationOnce(() => new Promise((resolve, reject) => {
      finishToggle = resolve
      failToggle = reject
    }))
    let latestRevision = 1
    const props = { targetType: 'post' as const, targetId: 'ordered-row', getLatestBatchRevision: () => latestRevision }
    const { rerender } = render(h(ReactionBar, { ...props, batchObservation: orderedBatch(1, 1) }))
    fireEvent.click(screen.getByRole('button', { name: '👍 리액션 1개' }))
    // The request starts before settlement, without delivering its loading render.
    latestRevision = 2
    await act(async () => {
      if (outcome === 'failure') failToggle(new Error('write unavailable'))
      else finishToggle({
        target_type: 'post', target_id: 'ordered-row', user_id: 'viewer', emoji: '👍', reacted: true,
        summary: [{ emoji: '👍', count: 2, reacted: true, recent_user_ids: ['viewer'] }],
      })
    })
    rerender(h(ReactionBar, { ...props, batchObservation: orderedBatch(2) }))
    const button = screen.getByRole('button', { name: outcome === 'success' ? '👍 리액션 2개' : '👍 리액션 확인 불가' })
    if (outcome === 'success') expect(button).toHaveAttribute('aria-pressed', 'true')
    else {
      expect(button).toBeDisabled()
      expect(button).not.toHaveAttribute('aria-pressed')
      expect(button).toHaveTextContent('1')
    }
    expect(toggleReaction).toHaveBeenCalledTimes(1)
    expect(fetchBoardReactionState).not.toHaveBeenCalled()

    latestRevision = 3
    rerender(h(ReactionBar, { ...props, batchObservation: orderedBatch(3, 3) }))
    expect(screen.getByRole('button', { name: '👍 리액션 3개' })).not.toBeDisabled()
  })

  it('revokes local authority when an overlapping batch is unavailable', async () => {
    vi.mocked(toggleReaction).mockResolvedValueOnce({
      target_type: 'post', target_id: 'ordered-row', user_id: 'viewer', emoji: '👍', reacted: true,
      summary: [{ emoji: '👍', count: 1, reacted: true, recent_user_ids: ['viewer'] }],
    })
    vi.mocked(fetchBoardReactionState).mockRejectedValueOnce(new Error('read unavailable'))
    let latestRevision = 1
    const props = { targetType: 'post' as const, targetId: 'ordered-row', getLatestBatchRevision: () => latestRevision }
    const { rerender } = render(h(ReactionBar, { ...props, batchObservation: orderedBatch(1) }))
    fireEvent.click(screen.getByRole('button', { name: '👍 리액션 0개' }))
    latestRevision = 2
    await waitFor(() => expect(screen.getByRole('button', { name: '👍 리액션 1개' })).toHaveAttribute('aria-pressed', 'true'))
    rerender(h(ReactionBar, { ...props, batchObservation: { state: 'unavailable', revision: 2 } }))
    await waitFor(() => expect(screen.getByRole('button', { name: '👍 리액션 확인 불가' })).toBeDisabled())
    const button = screen.getByRole('button', { name: '👍 리액션 확인 불가' })
    expect(button).not.toHaveAttribute('aria-pressed')
    expect(button).toHaveTextContent('1')
    expect(toggleReaction).toHaveBeenCalledTimes(1)
  })

  it.each(['success', 'failure'] as const)('fences a batch begun during an SSE read that settles with %s', async outcome => {
    let finishRead!: (value: Awaited<ReturnType<typeof fetchBoardReactionState>>) => void
    let failRead!: (error: Error) => void
    vi.mocked(fetchBoardReactionState).mockImplementationOnce(() => new Promise((resolve, reject) => {
      finishRead = resolve
      failRead = reject
    }))
    let latestRevision = 1
    const props = { targetType: 'post' as const, targetId: 'ordered-row', getLatestBatchRevision: () => latestRevision }
    const { rerender } = render(h(ReactionBar, { ...props, batchObservation: orderedBatch(1, 1) }))
    await act(async () => {
      lastEvent.value = { type: 'reaction_changed', target_type: 'post', target_id: 'ordered-row', user_id: 'other', emoji: '👍', reacted: true }
    })
    latestRevision = 2
    await act(async () => {
      if (outcome === 'failure') failRead(new Error('read unavailable'))
      else finishRead({
        summaries: [{ emoji: '👍', count: 2, reacted: true, recent_user_ids: ['other', 'viewer'] }], supportedEmojis: ['👍'],
      })
    })
    // No retained matching event is available to repair a later stale overwrite.
    lastEvent.value = null
    rerender(h(ReactionBar, { ...props, batchObservation: orderedBatch(2) }))
    if (outcome === 'success') expect(screen.getByRole('button', { name: '👍 리액션 2개' })).toHaveAttribute('aria-pressed', 'true')
    else expect(screen.getByRole('button', { name: '👍 리액션 확인 불가' })).toBeDisabled()
    expect(fetchBoardReactionState).toHaveBeenCalledTimes(1)
    expect(toggleReaction).not.toHaveBeenCalled()
  })
})

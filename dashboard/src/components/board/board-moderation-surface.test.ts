import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { BoardModerationSurface } from './board-moderation-surface'
import {
  fetchBoardModerationQueue,
  flagBoardModerationTarget,
  submitBoardModerationAction,
} from '../../api/board-moderation'
import {
  resetDashboardSessionActorForTests,
  setCanonicalDashboardActor,
} from '../../lib/dashboard-session-actor'

vi.mock('../../api/board-moderation', () => ({
  fetchBoardModerationQueue: vi.fn(),
  flagBoardModerationTarget: vi.fn(),
  submitBoardModerationAction: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

const fetchQueueMock = vi.mocked(fetchBoardModerationQueue)
const flagTargetMock = vi.mocked(flagBoardModerationTarget)
const submitActionMock = vi.mocked(submitBoardModerationAction)

describe('BoardModerationSurface', () => {
  beforeEach(() => {
    fetchQueueMock.mockResolvedValue({
      count: 1,
      entries: [
        {
          entry_id: 'flag-1',
          target_kind: 'post',
          target_id: 'post-1',
          reporter: 'keeper-a',
          reason: 'spam',
          flagged_at: 1_779_000_000,
          flagged_at_iso: '2026-05-17T06:40:00.000Z',
          resolved: false,
        },
      ],
    })
    flagTargetMock.mockResolvedValue({
      entry_id: 'flag-2',
      target_kind: 'comment',
      target_id: 'comment-2',
      reporter: 'operator',
      reason: 'harassment',
      flagged_at: 1_779_000_100,
      flagged_at_iso: '2026-05-17T06:41:40.000Z',
      resolved: false,
    })
    submitActionMock.mockResolvedValue({
      entry: {
        audit_id: 'audit-1',
        target_kind: 'post',
        target_id: 'post-1',
        actor: 'operator',
        action: 'hide',
        reason: 'spam',
        note: null,
        acted_at: 1_779_000_200,
        acted_at_iso: '2026-05-17T06:43:20.000Z',
      },
      delete_warning: null,
    })
  })

  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
    resetDashboardSessionActorForTests()
  })

  it('renders queue entries with moderation state', async () => {
    render(h(BoardModerationSurface, null))

    expect(await screen.findByText('post-1')).toBeTruthy()
    expect(screen.getByText('spam')).toBeTruthy()
    expect(screen.getByText('keeper-a')).toBeTruthy()
    expect(screen.getByText('open')).toBeTruthy()
    expect(fetchQueueMock).toHaveBeenCalledWith(expect.objectContaining({
      resolved: false,
      signal: expect.any(AbortSignal),
    }))
  })

  it('ignores aborted stale queue loads', async () => {
    let rejectFirst: ((reason?: unknown) => void) | null = null
    fetchQueueMock
      .mockImplementationOnce((options = {}) => new Promise((_, reject) => {
        const { signal } = options
        rejectFirst = reject
        signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
      }))
      .mockResolvedValueOnce({
        count: 1,
        entries: [
          {
            entry_id: 'flag-resolved',
            target_kind: 'post',
            target_id: 'post-resolved',
            reporter: 'keeper-b',
            reason: 'spam',
            flagged_at: 1_779_000_010,
            flagged_at_iso: '2026-05-17T06:40:10.000Z',
            resolved: true,
          },
        ],
      })

    render(h(BoardModerationSurface, null))
    await waitFor(() => expect(fetchQueueMock).toHaveBeenCalledTimes(1))
    fireEvent.change(screen.getByTestId('moderation-filter'), { target: { value: 'resolved' } })

    expect(rejectFirst).not.toBeNull()
    await screen.findByText('post-resolved')
    expect(screen.queryByText('post-1')).toBeNull()
    expect(fetchQueueMock.mock.calls[0]?.[0]?.signal?.aborted).toBe(true)
  })

  it('flags a target and reloads the queue', async () => {
    fetchQueueMock.mockResolvedValueOnce({ count: 0, entries: [] })
    render(h(BoardModerationSurface, null))

    await waitFor(() => expect(fetchQueueMock).toHaveBeenCalledTimes(1))
    fireEvent.change(screen.getByTestId('moderation-target-kind'), { target: { value: 'comment' } })
    fireEvent.input(screen.getByTestId('moderation-target-id'), { target: { value: ' comment-2 ' } })
    fireEvent.change(screen.getByTestId('moderation-reason'), { target: { value: 'harassment' } })
    fireEvent.input(screen.getByTestId('moderation-reporter'), { target: { value: ' operator ' } })
    fireEvent.click(screen.getByTestId('moderation-flag-submit'))

    await waitFor(() => expect(flagTargetMock).toHaveBeenCalledWith({
      target_kind: 'comment',
      target_id: ' comment-2 ',
      reporter: ' operator ',
      reason: 'harassment',
    }))
    expect(fetchQueueMock).toHaveBeenCalledTimes(2)
  })

  it('defaults the reporter to the current dashboard actor', async () => {
    setCanonicalDashboardActor('codex')
    fetchQueueMock.mockResolvedValueOnce({ count: 0, entries: [] })
    render(h(BoardModerationSurface, null))

    await waitFor(() => expect(fetchQueueMock).toHaveBeenCalledTimes(1))
    expect(screen.getByTestId('moderation-reporter')).toHaveValue('codex')
    fireEvent.input(screen.getByTestId('moderation-target-id'), { target: { value: 'post-2' } })
    fireEvent.click(screen.getByTestId('moderation-flag-submit'))

    await waitFor(() => expect(flagTargetMock).toHaveBeenCalledWith({
      target_kind: 'post',
      target_id: 'post-2',
      reporter: 'codex',
      reason: 'spam',
    }))
  })

  it('locks queue controls while a flag submission is in flight', async () => {
    const queuedEntry = {
      entry_id: 'flag-2',
      target_kind: 'comment',
      target_id: 'comment-2',
      reporter: 'operator',
      reason: 'harassment',
      flagged_at: 1_779_000_100,
      flagged_at_iso: '2026-05-17T06:41:40.000Z',
      resolved: false,
    } satisfies Awaited<ReturnType<typeof flagBoardModerationTarget>>
    let resolveFlag: (() => void) | null = null
    flagTargetMock.mockImplementationOnce(() => new Promise(resolve => {
      resolveFlag = () => resolve(queuedEntry)
    }))
    render(h(BoardModerationSurface, null))

    await screen.findByText('post-1')
    fireEvent.change(screen.getByTestId('moderation-target-kind'), { target: { value: 'comment' } })
    fireEvent.input(screen.getByTestId('moderation-target-id'), { target: { value: ' comment-2 ' } })
    fireEvent.change(screen.getByTestId('moderation-reason'), { target: { value: 'harassment' } })
    fireEvent.click(screen.getByTestId('moderation-flag-submit'))

    await waitFor(() => expect(flagTargetMock).toHaveBeenCalledTimes(1))
    expect(screen.getByTestId('moderation-filter')).toBeDisabled()
    expect(screen.getByLabelText('Refresh moderation queue')).toBeDisabled()
    const completeFlag = resolveFlag as (() => void) | null
    expect(completeFlag).not.toBeNull()
    completeFlag?.()
    await waitFor(() => expect(fetchQueueMock).toHaveBeenCalledTimes(2))
  })

  it('submits an action for an unresolved queue entry', async () => {
    render(h(BoardModerationSurface, null))

    await screen.findByText('post-1')
    fireEvent.click(screen.getByTestId('moderation-action-flag-1-hide'))

    await waitFor(() => expect(submitActionMock).toHaveBeenCalledWith({
      target_kind: 'post',
      target_id: 'post-1',
      action: 'hide',
      reason: 'spam',
    }))
    expect(fetchQueueMock).toHaveBeenCalledTimes(2)
  })

  it('locks queue controls while a moderation action is in flight', async () => {
    const actionResult = {
      entry: {
        audit_id: 'audit-1',
        target_kind: 'post',
        target_id: 'post-1',
        actor: 'operator',
        action: 'hide',
        reason: 'spam',
        note: null,
        acted_at: 1_779_000_200,
        acted_at_iso: '2026-05-17T06:43:20.000Z',
      },
      delete_warning: null,
    } satisfies Awaited<ReturnType<typeof submitBoardModerationAction>>
    let resolveAction: (() => void) | null = null
    submitActionMock.mockImplementationOnce(() => new Promise(resolve => {
      resolveAction = () => resolve(actionResult)
    }))
    render(h(BoardModerationSurface, null))

    await screen.findByText('post-1')
    fireEvent.click(screen.getByTestId('moderation-action-flag-1-hide'))

    await waitFor(() => expect(submitActionMock).toHaveBeenCalledTimes(1))
    expect(screen.getByTestId('moderation-filter')).toBeDisabled()
    expect(screen.getByLabelText('Refresh moderation queue')).toBeDisabled()
    const completeAction = resolveAction as (() => void) | null
    expect(completeAction).not.toBeNull()
    completeAction?.()
    await waitFor(() => expect(fetchQueueMock).toHaveBeenCalledTimes(2))
  })
})

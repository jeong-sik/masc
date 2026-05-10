import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchBoardModerationQueue,
  flagBoardModerationTarget,
  normalizeBoardModerationAuditEntry,
  normalizeBoardModerationQueueEntry,
  submitBoardModerationAction,
} from './board-moderation'

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

describe('board moderation api', () => {
  it('fetches the queue with resolved filter and drops malformed entries', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      ok: true,
      entries: [
        {
          entry_id: 'flag-1',
          target_kind: 'post',
          target_id: 'post-1',
          reporter: 'keeper-a',
          reason: 'spam',
          flagged_at: 1_779_000_000,
          resolved: false,
        },
        {
          entry_id: 'bad',
          target_kind: 'post',
          reporter: 'keeper-a',
          reason: 'spam',
          flagged_at: 1_779_000_000,
          resolved: false,
        },
      ],
      count: 2,
    }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoardModerationQueue({
      resolved: false,
      signal: new AbortController().signal,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/board/moderation/queue?resolved=false')
    const fetchSignal = (fetchMock.mock.calls[0]?.[1] as RequestInit | undefined)?.signal as AbortSignal | undefined
    expect(fetchSignal).toBeInstanceOf(AbortSignal)
    expect(fetchSignal?.aborted).toBe(false)
    expect(result.count).toBe(2)
    expect(result.entries).toHaveLength(1)
    expect(result.entries[0]?.entry_id).toBe('flag-1')
    expect(result.entries[0]?.flagged_at_iso).toBe('2026-05-17T06:40:00.000Z')
  })

  it('rejects when a queue fetch is aborted in flight', async () => {
    const controller = new AbortController()
    const fetchMock = vi.fn((_url: string, init?: RequestInit) => new Promise<Response>((_, reject) => {
      const signal = init?.signal as AbortSignal | undefined
      signal?.addEventListener(
        'abort',
        () => reject(new DOMException('aborted', 'AbortError')),
        { once: true },
      )
      controller.abort()
    }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchBoardModerationQueue({ signal: controller.signal })).rejects.toMatchObject({
      name: 'AbortError',
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('flags a target through the dashboard moderation route', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      ok: true,
      entry: {
        entry_id: 'flag-2',
        target_kind: 'post',
        target_id: 'post-2',
        reporter: 'keeper-b',
        reason: 'policy:duplicate',
        flagged_at: 1_779_000_100,
        resolved: false,
      },
    }))
    vi.stubGlobal('fetch', fetchMock)

    const entry = await flagBoardModerationTarget({
      target_id: ' post-2 ',
      reporter: ' keeper-b ',
      reason: 'policy:duplicate',
    })

    expect(entry.entry_id).toBe('flag-2')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/dashboard/board/moderation/flag')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({
      target_kind: 'post',
      target_id: 'post-2',
      reporter: 'keeper-b',
      reason: 'policy:duplicate',
    })
  })

  it('submits a moderation action and preserves delete warnings', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      ok: true,
      entry: {
        audit_id: 'audit-1',
        target_kind: 'comment',
        target_id: 'comment-1',
        actor: 'operator-a',
        action: 'remove',
        reason: 'harassment',
        note: 'remove offensive comment',
        acted_at: 1_779_000_200,
      },
      delete_warning: 'comment removal is audit-only',
    }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await submitBoardModerationAction({
      target_kind: 'comment',
      target_id: ' comment-1 ',
      action: 'remove',
      actor: ' operator-a ',
      reason: 'harassment',
      note: ' remove offensive comment ',
    })

    expect(result.entry.audit_id).toBe('audit-1')
    expect(result.delete_warning).toBe('comment removal is audit-only')
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/dashboard/board/moderation/action')
    expect(JSON.parse(String(init.body))).toEqual({
      target_kind: 'comment',
      target_id: 'comment-1',
      action: 'remove',
      actor: 'operator-a',
      reason: 'harassment',
      note: 'remove offensive comment',
    })
  })

  it('rejects invalid target kinds instead of falling back to posts', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    await expect(flagBoardModerationTarget({
      target_kind: 'message' as never,
      target_id: 'post-1',
    })).rejects.toThrow('unknown board moderation target_kind: message; valid: post, comment')

    await expect(submitBoardModerationAction({
      target_kind: 'message' as never,
      target_id: 'post-1',
      action: 'approve',
    })).rejects.toThrow('unknown board moderation target_kind: message; valid: post, comment')

    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('names rejected moderation actions and reasons with valid options', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    await expect(submitBoardModerationAction({
      target_id: 'post-1',
      action: 'delete' as never,
    })).rejects.toThrow('unknown board moderation action: delete; valid: approve, remove, hide, warn')

    await expect(flagBoardModerationTarget({
      target_id: 'post-1',
      reason: 'duplicate' as never,
    })).rejects.toThrow(
      'unknown board moderation reason: duplicate; valid: spam, harassment, off_topic, policy:<non-empty>',
    )

    await expect(submitBoardModerationAction({
      target_id: 'post-1',
      action: 'approve',
      reason: 'duplicate' as never,
    })).rejects.toThrow(
      'unknown board moderation reason: duplicate; valid: spam, harassment, off_topic, policy:<non-empty>',
    )

    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns null for malformed queue and audit entries', () => {
    expect(normalizeBoardModerationQueueEntry({
      entry_id: 'flag-1',
      target_kind: 'post',
      reporter: 'keeper-a',
      reason: 'spam',
      flagged_at: 1,
      resolved: false,
    })).toBeNull()

    expect(normalizeBoardModerationAuditEntry({
      audit_id: 'audit-1',
      target_kind: 'post',
      target_id: 'post-1',
      actor: 'operator-a',
      action: 'delete',
      acted_at: 1,
    })).toBeNull()

    expect(normalizeBoardModerationQueueEntry({
      entry_id: 'flag-zero',
      target_kind: 'post',
      target_id: 'post-1',
      reporter: 'keeper-a',
      reason: 'spam',
      flagged_at: 0,
      resolved: false,
    })).toBeNull()

    expect(normalizeBoardModerationAuditEntry({
      audit_id: 'audit-negative',
      target_kind: 'post',
      target_id: 'post-1',
      actor: 'operator-a',
      action: 'approve',
      acted_at: -1,
    })).toBeNull()
  })
})

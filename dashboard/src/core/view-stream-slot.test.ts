import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  bootstrapAuthSession,
  bumpSessionEpoch,
  resetAuthStateForTests,
  setSingleUserToken,
} from './auth'
import {
  extractObserverTopics,
  observerConnected,
  observerLastEventId,
  parseSseBlock,
  resetObserverStateForTests,
  resolveObserverEndpoint,
  startObserverStream,
  subscribeObserverResync,
  viewProvenance,
} from './observer'
import { resourceCache } from './resource-cache'
import { ok } from '../lib/result'
import {
  CROSSHAIR_SYNC_KEY,
  getUPlotSync,
  publishCrosshair,
  resetTimeWindowForTests,
  setTimeWindow,
  timeWindow,
  timeWindowProviderDays,
  timeWindowSeconds,
  crosshairCursor,
} from './time-window'
import {
  acquireViewStream,
  activeViewStreamKey,
  getViewStreamGeneration,
  releaseAllViewStreams,
  viewStreamPaused,
} from './view-stream-slot'

function setDocumentHidden(hidden: boolean): void {
  Object.defineProperty(document, 'hidden', { configurable: true, value: hidden })
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    value: hidden ? 'hidden' : 'visible',
  })
  document.dispatchEvent(new Event('visibilitychange'))
}

describe('core/view-stream-slot (2+1 SSE invariant)', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    releaseAllViewStreams()
    setDocumentHidden(false)
  })

  afterEach(() => {
    releaseAllViewStreams()
    setDocumentHidden(false)
    resetAuthStateForTests()
  })

  it('preempts the prior view stream immediately and bumps monotonic generation', () => {
    const signals: AbortSignal[] = []
    const cleanups: string[] = []

    const h1 = acquireViewStream('keeper:sangsu', (sig) => {
      signals.push(sig)
      return () => cleanups.push('h1')
    })
    const gen1 = h1.generation
    expect(activeViewStreamKey.value).toBe('keeper:sangsu')
    expect(signals[0]!.aborted).toBe(false)

    const h2 = acquireViewStream('logs:tail', (sig) => {
      signals.push(sig)
      return () => cleanups.push('h2')
    })
    expect(signals[0]!.aborted).toBe(true)
    expect(cleanups).toEqual(['h1'])
    expect(activeViewStreamKey.value).toBe('logs:tail')
    expect(h2.generation).toBeGreaterThan(gen1)
    expect(getViewStreamGeneration()).toBe(h2.generation)

    // Releasing an already-preempted handle is a safe no-op
    h1.release()
    expect(activeViewStreamKey.value).toBe('logs:tail')

    h2.release()
    expect(signals[1]!.aborted).toBe(true)
    expect(cleanups).toEqual(['h1', 'h2'])
    expect(activeViewStreamKey.value).toBeNull()
  })

  it('auto-pauses on document.hidden and reconnects when visible again', () => {
    const connectSpy = vi.fn((_sig: AbortSignal) => {})
    const handle = acquireViewStream('trace:live', connectSpy)
    expect(connectSpy).toHaveBeenCalledTimes(1)
    expect(viewStreamPaused.value).toBe(false)

    setDocumentHidden(true)
    expect(viewStreamPaused.value).toBe(true)
    expect(connectSpy.mock.calls[0]![0].aborted).toBe(true)

    setDocumentHidden(false)
    expect(viewStreamPaused.value).toBe(false)
    expect(connectSpy).toHaveBeenCalledTimes(2)
    expect(connectSpy.mock.calls[1]![0].aborted).toBe(false)
    handle.release()
  })

  it('auto-releases active view stream when sessionEpoch advances', () => {
    let aborted = false
    acquireViewStream('keeper:live', (sig) => {
      sig.addEventListener('abort', () => { aborted = true })
    })
    expect(activeViewStreamKey.value).toBe('keeper:live')

    bumpSessionEpoch()
    expect(aborted).toBe(true)
    expect(activeViewStreamKey.value).toBeNull()
  })

  it('cleans up controller and slot state if connect throws synchronously', () => {
    const captured: AbortSignal[] = []
    expect(() =>
      acquireViewStream('broken:stream', (sig) => {
        captured.push(sig)
        throw new Error('sync connect failure')
      }),
    ).toThrow('sync connect failure')

    expect(captured[0]?.aborted).toBe(true)
    expect(activeViewStreamKey.value).toBeNull()

    // Slot remains healthy for subsequent views
    const h = acquireViewStream('healthy:stream', () => {})
    expect(activeViewStreamKey.value).toBe('healthy:stream')
    h.release()
  })
})

describe('core/observer & core/time-window', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetTimeWindowForTests('24h')
  })

  afterEach(() => {
    resetObserverStateForTests()
    resetAuthStateForTests()
    resetTimeWindowForTests('24h')
  })

  it('selects /api/v1/auth/events in multi_account and /mcp?sse_kind=observer in single_user', () => {
    const multi = resolveObserverEndpoint({
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'a1',
      email: null,
      displayName: 'A1',
      role: 'admin',
      csrfToken: 'csrf-1',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    })
    expect(multi?.url).toBe('/api/v1/auth/events')
    expect(multi?.headers.Authorization).toBeUndefined()

    setSingleUserToken('single-val-2')
    const single = resolveObserverEndpoint({
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    })
    expect(single?.url).toBe('/mcp?sse_kind=observer')
    expect(single?.headers.Authorization).toBe('Bearer single-val-2')
  })

  it('parses SSE frames and transitions provenance to STREAM_GAP on observer_resync_required', async () => {
    const parsed = parseSseBlock('id: 99\nevent: board_changed\ndata: {"type":"board_changed"}\n')
    expect(parsed?.id).toBe('99')
    expect(parsed?.event).toBe('board_changed')

    // JSON-RPC framed notifications/board carrying params.type or params.event_type
    const jsonRpcFrame = parseSseBlock(
      'id: 100\nevent: message\ndata: {"jsonrpc":"2.0","method":"notifications/board","params":{"type":"board_changed","event_type":"post_created"}}\n',
    )!
    expect(extractObserverTopics(jsonRpcFrame)).toEqual(
      expect.arrayContaining(['notifications/board', 'board_changed', 'post_created']),
    )

    // Verify JSON-RPC observer frame invalidates matching ResourceCache topics live
    await resourceCache.fetch('board:feed', async () => ok({ posts: 1 }), {
      ttlMs: 60_000,
      topics: ['board_changed'],
    })
    const boardSig = resourceCache.observe<{ posts: number }>('board:feed')
    expect(boardSig.value.kind === 'value' && boardSig.value.stale).toBe(false)

    const encoder = new TextEncoder()
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(
          encoder.encode(
            'id: 10\nevent: message\ndata: {"jsonrpc":"2.0","method":"notifications/board","params":{"type":"board_changed"}}\n\n',
          ),
        )
        controller.enqueue(encoder.encode('event: observer_resync_required\ndata: {"reason":"gap"}\n\n'))
        controller.close()
      },
    })

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return new Response(JSON.stringify({ account_mode: 'Multi_account' }))
      if (url === '/auth/session') {
        return new Response(
          JSON.stringify({ user_id: 'acct-1', expires_at_ms: 1_800_000_000_000, csrf_token: 'c1' }),
        )
      }
      if (url === '/api/v1/auth/whoami') {
        return new Response(
          JSON.stringify({ principal: { kind: 'human', id: 'acct-1' }, role: 'admin' }),
        )
      }
      if (url === '/api/v1/auth/events') {
        return new Response(stream, {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        })
      }
      throw new Error(`unexpected ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    const resyncReasons: string[] = []
    const unsub = subscribeObserverResync((r) => resyncReasons.push(r))

    await startObserverStream({ fetchImpl: fetchMock as unknown as typeof fetch })
    unsub()

    expect(observerLastEventId.value).toBe('10')
    expect(boardSig.value.kind === 'value' && boardSig.value.stale).toBe(true)
    expect(viewProvenance.value).toBe('STREAM_GAP')
    expect(resyncReasons).toContain('observer_resync_required')
    expect(observerConnected.value).toBe(false)
  })

  it('syncs TimeWindow with URL ?win=, maps provider days, and shares uPlot crosshair bus', () => {
    setTimeWindow('7d')
    expect(timeWindow.value).toBe('7d')
    expect(window.location.search).toContain('win=7d')
    expect(timeWindowSeconds('7d')).toBe(7 * 86_400)
    expect(timeWindowProviderDays('24h')).toBe(1)
    expect(timeWindowProviderDays('7d')).toBe(7)
    expect(timeWindowProviderDays('30d')).toBe(14)

    publishCrosshair(1_700_000_123, 'cost-chart')
    expect(crosshairCursor.value).toEqual({ timestamp: 1_700_000_123, sourceId: 'cost-chart' })

    const syncSpy = vi.fn((key: string) => ({ key }))
    const s1 = getUPlotSync({ sync: syncSpy })
    const s2 = getUPlotSync({ sync: syncSpy })
    expect(s1).toBe(s2)
    expect(syncSpy).toHaveBeenCalledTimes(1)
    expect(syncSpy).toHaveBeenCalledWith(CROSSHAIR_SYNC_KEY)
  })
})

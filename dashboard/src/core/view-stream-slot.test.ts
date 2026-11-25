import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  bootstrapAuthSession,
  bumpSessionEpoch,
  resetAuthStateForTests,
  setSingleUserToken,
} from './auth'
import {
  OBSERVER_SSE_INSTANCE_HEADER,
  extractObserverTopics,
  getObserverSseInstanceId,
  markStreamGap,
  markViewSynced,
  observerConnected,
  observerLastEventId,
  observerSseInstanceId,
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
    resourceCache.clearAll()
  })

  afterEach(() => {
    resetObserverStateForTests()
    resetAuthStateForTests()
    resetTimeWindowForTests('24h')
    resourceCache.clearAll()
  })

  it('refreshes a published Dashboard observation without reloading Fleet slots for preview frames', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const gate = vi.fn(async () => ok('gate snapshot'))
    const fleet = vi.fn(async () => ok('fleet slots'))
    const gateRead = () => resourceCache.fetch('gate:queue', gate, { topics: ['gate'], reason: 'sse' })
    const fleetRead = () => resourceCache.fetch('keepers:roster', fleet, { topics: ['keeper', 'keeper_turn'], reason: 'sse' })
    await Promise.all([gateRead(), fleetRead()])

    const observation = { type: 'workspace_dataset_changed', dataset: 'dashboard_observation', topic: 'gate', scope: 'workspace' }
    const preview = { type: 'keeper_turn_preview_changed', name: 'alpha', observation: { owner_key: 'owner', preview: { revision: 3 } } }
    const send = async (...payloads: unknown[]) => {
      const body = payloads.map((data) => `data: ${JSON.stringify(data)}\n\n`).join('')
      await startObserverStream({ fetchImpl: async () => new Response(body), autoReconnect: false })
    }
    await send(preview, preview, { jsonrpc: '2.0', method: 'notifications/message', params: observation })
    await Promise.all([gateRead(), fleetRead()])
    expect({ gateReads: gate.mock.calls.length, fleetReads: fleet.mock.calls.length }).toEqual({ gateReads: 2, fleetReads: 1 })

    await send(observation, { type: 'keeper_turn_changed', name: 'alpha' })
    await Promise.all([gateRead(), fleetRead()])
    expect({ gateReads: gate.mock.calls.length, fleetReads: fleet.mock.calls.length }).toEqual({ gateReads: 3, fleetReads: 2 })
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

  it('captures x-masc-sse-instance-id response header from observer stream and clears it on sessionEpoch bump', async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.close()
      },
    })

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/mcp?sse_kind=observer') {
        return new Response(stream, {
          status: 200,
          headers: {
            'Content-Type': 'text/event-stream',
            [OBSERVER_SSE_INSTANCE_HEADER]: 'rt-inst-8935.epoch-4',
          },
        })
      }
      throw new Error(`unexpected ${url}`)
    })

    setSingleUserToken('tok-obs-1')
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    await startObserverStream({ fetchImpl: fetchMock as unknown as typeof fetch })

    expect(observerSseInstanceId.value).toBe('rt-inst-8935.epoch-4')
    expect(getObserverSseInstanceId()).toBe('rt-inst-8935.epoch-4')

    // Bumping sessionEpoch clears cached observerSseInstanceId
    bumpSessionEpoch()
    expect(observerSseInstanceId.value).toBeNull()
    expect(getObserverSseInstanceId()).toBeNull()
  })

  it('preserves STREAM_GAP across markViewSynced, extracts dataset topics, and auto-reconnects after drop', async () => {
    // 1. markViewSynced must not erase STREAM_GAP while disconnected
    markStreamGap('observer_disconnected')
    expect(viewProvenance.value).toBe('STREAM_GAP')
    markViewSynced()
    expect(viewProvenance.value).toBe('STREAM_GAP')

    // 2. extractObserverTopics extracts server dataset + maps aliases
    const dsFrame = parseSseBlock(
      'event: workspace_dataset_changed\ndata: {"dataset":"provider_standing","type":"keeper_row_changed"}\n',
    )!
    expect(extractObserverTopics(dsFrame)).toEqual(
      expect.arrayContaining(['workspace_dataset_changed', 'provider_standing', 'keeper_row_changed', 'keeper', 'provider', 'quota']),
    )

    // 3. Auto-reconnect schedules a retry after transient drop and restores LIVE SSE
    let calls = 0
    const fetchMock = vi.fn(async () => {
      calls += 1
      if (calls === 1) {
        return new Response(null, { status: 503 })
      }
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(': keepalive\n\n'))
        },
      })
      return new Response(stream, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })
    })

    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    await startObserverStream({
      fetchImpl: fetchMock as unknown as typeof fetch,
      reconnectBaseDelayMs: 15,
    })
    expect(calls).toBe(1)
    expect(viewProvenance.value).toBe('STREAM_GAP')

    await new Promise((r) => setTimeout(r, 60))
    expect(calls).toBe(2)
    expect(observerConnected.value).toBe(true)
    expect(viewProvenance.value).toBe('LIVE SSE')
  })

  it('does not coalesce post-invalidation reconnect fetch into stale in-flight request or clear invalidation on stale arrival', async () => {
    let resolveStale!: (v: ReturnType<typeof ok<string>>) => void
    const stalePromise = new Promise<ReturnType<typeof ok<string>>>((resolve) => {
      resolveStale = resolve
    })
    let staleAborted = false
    let fetchCount = 0

    // 1. Pre-reconnect in-flight request begins while SSE is disconnected
    const p1 = resourceCache.fetch(
      'inbox:snapshot',
      (signal) => {
        fetchCount += 1
        signal.addEventListener('abort', () => { staleAborted = true })
        return stalePromise
      },
      { ttlMs: 60_000, topics: ['approval', 'ask'], reason: 'mount' },
    )
    expect(fetchCount).toBe(1)

    // 2. Observer reconnect calls invalidateAll(), then listener immediately requests a fresh read
    resourceCache.invalidateAll()
    const p2 = resourceCache.fetch(
      'inbox:snapshot',
      async () => {
        fetchCount += 1
        return ok('fresh-after-reconnect')
      },
      { ttlMs: 60_000, topics: ['approval', 'ask'], reason: 'sse' },
    )

    // Must NOT coalesce into p1; must abort p1 and issue fetch #2
    expect(fetchCount).toBe(2)
    expect(staleAborted).toBe(true)

    const freshObs = await p2
    expect(freshObs.kind === 'value' && freshObs.data).toBe('fresh-after-reconnect')
    expect(freshObs.kind === 'value' && freshObs.stale).toBe(false)

    // Even if the stale pre-disconnect response resolves late, it must NOT overwrite fresh state
    resolveStale(ok('stale-during-disconnect'))
    await p1
    const afterLate = resourceCache.peek<string>('inbox:snapshot')
    expect(afterLate?.kind === 'value' && afterLate.data).toBe('fresh-after-reconnect')
    expect(afterLate?.kind === 'value' && afterLate.stale).toBe(false)

    // 3. Also verify: if an in-flight request started BEFORE invalidation settles BEFORE
    // any new fetch is requested, it must remain marked stale/invalidated so the next fetch still runs.
    let resolveMid!: (v: ReturnType<typeof ok<string>>) => void
    const midPromise = new Promise<ReturnType<typeof ok<string>>>((resolve) => {
      resolveMid = resolve
    })
    const p3 = resourceCache.fetch(
      'inbox:mid',
      () => midPromise,
      { ttlMs: 60_000, topics: ['approval'], reason: 'mount' },
    )
    resourceCache.invalidateTopic('approval')
    resolveMid(ok('pre-invalidation-payload'))
    const midObs = await p3
    expect(midObs.kind === 'value' && midObs.stale).toBe(true)

    let postCalls = 0
    const postObs = await resourceCache.fetch(
      'inbox:mid',
      async () => {
        postCalls += 1
        return ok('post-invalidation-payload')
      },
      { ttlMs: 60_000, topics: ['approval'], reason: 'sse' },
    )
    expect(postCalls).toBe(1)
    expect(postObs.kind === 'value' && postObs.data).toBe('post-invalidation-payload')
    expect(postObs.kind === 'value' && postObs.stale).toBe(false)
  })
})

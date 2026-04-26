import { afterEach, describe, expect, it, vi } from 'vitest'

const { runOperatorAction, currentDashboardActor } = vi.hoisted(() => ({
  runOperatorAction: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard'),
}))

vi.mock('./core', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./core')>()
  return {
    ...actual,
    currentDashboardActor,
    runOperatorAction,
  }
})

import {
  bootKeeper,
  clearKeeper,
  deleteKeeperHistorySnapshots,
  fetchKeeperCheckpoints,
  pauseKeeper,
  resumeKeeper,
  sendKeeperMessageDetailed,
  shutdownKeeper,
  streamKeeperMessage,
  wakeupKeeper,
} from './keeper'

afterEach(() => {
  vi.clearAllMocks()
  vi.unstubAllGlobals()
  try {
    window.localStorage?.removeItem?.('masc_dashboard_agent_name')
  } catch {
    // Ignore storage cleanup failures in the test environment.
  }
})

describe('sendKeeperMessageDetailed', () => {
  it('forces direct reply mode for operator-mediated direct chats', async () => {
    runOperatorAction.mockResolvedValueOnce({
      result: {
        reply: 'pong',
        model_used: 'test-model',
      },
    })

    const reply = await sendKeeperMessageDetailed('sangsu', 'ping')

    expect(currentDashboardActor).toHaveBeenCalled()
    expect(runOperatorAction).toHaveBeenCalledWith({
      actor: 'dashboard',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'sangsu',
      payload: {
        message: 'ping',
        direct_reply: true,
      },
    })
    expect(reply.text).toBe('pong')
  })
})

describe('streamKeeperMessage', () => {
  it('posts direct reply mode to the keeper chat stream endpoint', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta%E3%85%8A')

    const fetchMock = vi.fn().mockResolvedValue(
      new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const events: string[] = []
    await streamKeeperMessage('sangsu', 'ping', {
      onEvent: event => {
        events.push(event.type)
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    expect(JSON.parse(String(init.body))).toEqual({
      name: 'sangsu',
      message: 'ping',
      direct_reply: true,
    })
    const actorHeader = headers['X-MASC-Agent'] ?? headers['x-masc-agent']
    expect(actorHeader).toBe('dashboard-eager-manta')
    expect(actorHeader).not.toContain('%')
    expect(events).toEqual(['RUN_FINISHED'])
  })
})

describe('keeper lifecycle', () => {
  it('treats unauthorized shutdown responses as failures', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: 'Token required' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await shutdownKeeper('keeper-test')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Token required')
  })

  it('falls back to the HTTP status when boot failure payload is not json', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('auth gateway failed', {
        status: 502,
        headers: { 'Content-Type': 'text/plain' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await bootKeeper('keeper-test')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Failed to boot keeper-test (HTTP 502): auth gateway failed')
  })

  it('falls back to the HTTP status when boot failure payload is not JSON', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('null', {
        status: 502,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await bootKeeper('keeper-test')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Failed to boot keeper-test (HTTP 502)')
  })

  it('posts keeper clear payload and returns structured detail', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        action: 'clear',
        name: 'keeper-test',
        detail: {
          cleared_message_count: 12,
          continuity_cleared: true,
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await clearKeeper('keeper-test', {
      reason: 'reset stale continuity',
      preserve_system_prompt: true,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-test/clear')
    expect(JSON.parse(String(init.body))).toEqual({
      reason: 'reset stale continuity',
      preserve_system_prompt: true,
    })
    expect(result.ok).toBe(true)
    expect(result.action).toBe('clear')
    expect(result.detail).toEqual({
      cleared_message_count: 12,
      continuity_cleared: true,
    })
  })

  it('fetches keeper checkpoint inventory from the admin route', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        keeper: 'keeper-test',
        trace_id: 'trace-keeper-test',
        session_dir: '/tmp/trace-keeper-test',
        current: null,
        history: [],
        legacy_shadow_count: 0,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperCheckpoints('keeper-test')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/keepers/keeper-test/checkpoints',
      expect.objectContaining({
        method: 'GET',
      }),
    )
    expect(result.trace_id).toBe('trace-keeper-test')
    expect(result.history).toEqual([])
  })

  it('posts selected OAS history snapshot ids for deletion', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        action: 'delete_history',
        keeper: 'keeper-test',
        deleted_snapshot_ids: ['oas-snapshot-1.json'],
        missing_snapshot_ids: [],
        inventory: {
          keeper: 'keeper-test',
          trace_id: 'trace-keeper-test',
          session_dir: '/tmp/trace-keeper-test',
          current: null,
          history: [],
          legacy_shadow_count: 0,
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await deleteKeeperHistorySnapshots('keeper-test', ['oas-snapshot-1.json'])

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-test/checkpoints')
    expect(JSON.parse(String(init.body))).toEqual({
      action: 'delete_history',
      snapshot_ids: ['oas-snapshot-1.json'],
    })
    expect(result.deleted_snapshot_ids).toEqual(['oas-snapshot-1.json'])
  })

  it('sends POST with action=pause via directive endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, action: 'pause', name: 'janitor' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await pauseKeeper('janitor')

    expect(result.ok).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/janitor/directive')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body)).toEqual({ action: 'pause' })
  })

  it('sends POST with action=resume via directive endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, action: 'resume', name: 'janitor' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await resumeKeeper('janitor')

    expect(result.ok).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/janitor/directive')
    expect(JSON.parse(init.body)).toEqual({ action: 'resume' })
  })

  it('sends POST with action=wakeup via directive endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, action: 'wakeup', name: 'sangsu' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await wakeupKeeper('sangsu')

    expect(result.ok).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/sangsu/directive')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body)).toEqual({ action: 'wakeup' })
  })

  it('encodes keeper name in wakeup directive URL', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await wakeupKeeper('keeper with space')

    const [url] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/keeper%20with%20space/directive')
  })

  it('returns error when pause directive fails', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: false, error: 'Keeper not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await pauseKeeper('nonexistent')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Keeper not found')
  })
})

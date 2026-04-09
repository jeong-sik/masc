import { afterEach, describe, expect, it, vi } from 'vitest'
import { defaultBoardVoter, get, post } from './core'

afterEach(() => {
  vi.unstubAllGlobals()
  try {
    window.history.replaceState({}, '', 'http://localhost/')
  } catch {
    // Ignore cleanup failures in the test environment.
  }
})

describe('post', () => {
  it('sends a sanitized actor header without URL encoding', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta%E3%85%8A')

    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await post('/api/v1/tools/masc_board_comment', { post_id: 'p-123', content: 'hello' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    const actorHeader = headers['X-MASC-Agent'] ?? headers['x-masc-agent']
    expect(actorHeader).toBe('dashboard-eager-manta')
    expect(actorHeader).not.toContain('%')
  })

  it('keeps board voter resolution scoped to query params', () => {
    window.localStorage?.setItem?.('masc_dashboard_agent_name', 'stored-agent')
    window.history.replaceState({}, '', '/')

    expect(defaultBoardVoter()).toBe('dashboard-user')
  })
})

describe('get bootstrap warm-up mapping', () => {
  it('preserves upstream abort signals instead of reporting them as timeouts', async () => {
    const fetchMock = vi.fn().mockImplementation((_path: string, init?: RequestInit) => (
      new Promise((_resolve, reject) => {
        const signal = init?.signal as AbortSignal | undefined
        signal?.addEventListener('abort', () => {
          reject(new DOMException('superseded request', 'AbortError'))
        })
      })
    ))
    vi.stubGlobal('fetch', fetchMock)

    const controller = new AbortController()
    const request = get('/api/v1/dashboard/namespace-truth', { signal: controller.signal })
    controller.abort()

    await expect(request).rejects.toMatchObject({
      name: 'AbortError',
    })
  })

  it('maps dashboard namespace-truth not-initialized errors to initializing payloads', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; message?: string }>('/api/v1/dashboard/namespace-truth')

    expect(data.status).toBe('initializing')
    expect(data.message).toContain('warming up')
  })

  it('maps dashboard shell not-initialized errors to an empty bootstrap shell payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      status?: { project?: string }
      counts?: { agents?: number; tasks?: number; keepers?: number }
    }>('/api/v1/dashboard/shell')

    expect(data.status?.project).toBe('initializing')
    expect(data.counts).toEqual({ agents: 0, tasks: 0, keepers: 0 })
  })

  it('preserves errors for non-bootstrap routes', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/board')).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 500,
      path: '/api/v1/board',
    })
  })

  it('does not remap 4xx bootstrap responses', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/namespace-truth')).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 401,
      path: '/api/v1/dashboard/namespace-truth',
    })
  })

  it('remaps 2xx not-initialized responses on bootstrap paths', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; message?: string }>('/api/v1/dashboard/namespace-truth')

    expect(data.status).toBe('initializing')
    expect(data.message).toContain('warming up')
  })

  it('remaps room-truth alias the same as namespace-truth', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; message?: string }>('/api/v1/dashboard/room-truth')

    expect(data.status).toBe('initializing')
    expect(data.message).toContain('warming up')
  })

  it('maps execution not-initialized 5xx to empty execution payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      generated_at?: string
      execution_queue?: unknown[]
      session_briefs?: unknown[]
      agents?: unknown[]
    }>('/api/v1/dashboard/execution')

    expect(data.generated_at).toBeDefined()
    expect(data.execution_queue).toEqual([])
    expect(data.session_briefs).toEqual([])
    expect(data.agents).toEqual([])
  })

  it('maps planning not-initialized 2xx to empty planning payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      generated_at?: string
      goals?: unknown[]
      task_backlog?: { todo?: number }
    }>('/api/v1/dashboard/planning')

    expect(data.generated_at).toBeDefined()
    expect(data.goals).toEqual([])
    expect(data.task_backlog?.todo).toBe(0)
  })

  it('maps mission not-initialized 5xx to empty mission payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      generated_at?: string
      summary?: { room_health?: string }
      incidents?: unknown[]
      command_focus?: { session_cards?: unknown[] }
      operator_targets?: { sessions?: unknown[] }
    }>('/api/v1/dashboard/mission')

    expect(data.generated_at).toBeDefined()
    expect(data.summary?.room_health).toBe('initializing')
    expect(data.incidents).toEqual([])
    expect(data.command_focus?.session_cards).toEqual([])
    expect(data.operator_targets?.sessions).toEqual([])
  })

  it('passes through valid 2xx responses on bootstrap paths', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"status":"ok","agents":5}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; agents?: number }>('/api/v1/dashboard/namespace-truth')

    expect(data.status).toBe('ok')
    expect(data.agents).toBe(5)
  })
})

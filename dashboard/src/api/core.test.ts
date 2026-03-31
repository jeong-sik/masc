import { afterEach, describe, expect, it, vi } from 'vitest'
import { post } from './core'

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
})

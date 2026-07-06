import { afterEach, describe, expect, it, vi } from 'vitest'
import { bulkKeeperDirective } from './keeper'

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockClear()
  vi.unstubAllGlobals()
})

function stubFetch(response: unknown, init: { ok?: boolean; status?: number } = {}): void {
  mockFetch.mockResolvedValue({
    ok: init.ok ?? true,
    status: init.status ?? 200,
    statusText: 'OK',
    headers: new Headers(),
    json: () => Promise.resolve(response),
    text: () => Promise.resolve(JSON.stringify(response)),
    clone() { return this },
  } as Response)
  vi.stubGlobal('fetch', mockFetch)
}

describe('bulkKeeperDirective', () => {
  it('posts names and action to the bulk endpoint and returns the parsed response', async () => {
    const expected = {
      ok: true,
      action: 'resume',
      requested: 2,
      succeeded: 2,
      results: [
        { name: 'rondo', ok: true },
        { name: 'qa-king', ok: true },
      ],
    }
    stubFetch(expected)

    const res = await bulkKeeperDirective(['rondo', 'qa-king'], 'resume')

    const call = mockFetch.mock.calls[0]!
    const init = call[1] as RequestInit
    expect(call[0]).toBe('/api/v1/keepers_bulk/directive')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      names: ['rondo', 'qa-king'],
      action: 'resume',
    })
    expect(res).toEqual(expected)
  })

  it('surfaces per-keeper failures from the results array on partial success', async () => {
    stubFetch({
      ok: true,
      action: 'resume',
      requested: 2,
      succeeded: 1,
      results: [
        { name: 'rondo', ok: true },
        { name: 'ghost', ok: false, error: 'keeper meta not found' },
      ],
    })

    const res = await bulkKeeperDirective(['rondo', 'ghost'], 'resume')

    expect(res.ok).toBe(true)
    expect(res.succeeded).toBe(1)
    expect(res.results[1]!.ok).toBe(false)
    expect(res.results[1]!.error).toBe('keeper meta not found')
  })

  it('preserves best-effort wakeup meta read errors from successful rows', async () => {
    stubFetch({
      ok: true,
      action: 'wakeup',
      requested: 1,
      succeeded: 1,
      failed: 0,
      meta_read_error_count: 1,
      results: [
        {
          name: 'sangsu',
          ok: true,
          meta_read_status: 'read_error',
          meta_read_error: 'malformed keeper meta',
        },
      ],
    })

    const res = await bulkKeeperDirective(['sangsu'], 'wakeup')

    expect(res.ok).toBe(true)
    expect(res.meta_read_error_count).toBe(1)
    expect(res.results[0]!.ok).toBe(true)
    expect(res.results[0]!.meta_read_status).toBe('read_error')
    expect(res.results[0]!.meta_read_error).toBe('malformed keeper meta')
  })

  it('returns a synthetic all-failed response when the HTTP call fails', async () => {
    stubFetch({ error: 'unauthorized' }, { ok: false, status: 401 })

    const res = await bulkKeeperDirective(['rondo', 'qa-king'], 'pause')

    expect(res.ok).toBe(false)
    expect(res.action).toBe('pause')
    expect(res.requested).toBe(2)
    expect(res.succeeded).toBe(0)
    expect(res.results).toHaveLength(2)
    expect(res.results.every(r => r.ok === false)).toBe(true)
  })

  it('returns a synthetic all-failed response when fetch throws', async () => {
    mockFetch.mockRejectedValue(new Error('network down'))
    vi.stubGlobal('fetch', mockFetch)

    const res = await bulkKeeperDirective(['rondo'], 'wakeup')

    expect(res.ok).toBe(false)
    expect(res.action).toBe('wakeup')
    expect(res.results[0]!.error).toBe('network down')
  })
})

import { afterEach, describe, expect, it, vi } from 'vitest'
import { bulkKeeperDirective } from './keeper'

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockClear()
  vi.unstubAllGlobals()
})

function stubFetch(response: unknown, init: { ok?: boolean; status?: number } = {}): void {
  mockFetch.mockResolvedValue(mockResponse(response, init))
  vi.stubGlobal('fetch', mockFetch)
}

function mockResponse(
  response: unknown,
  init: { ok?: boolean; status?: number } = {},
): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    statusText: 'OK',
    headers: new Headers(),
    json: () => Promise.resolve(response),
    text: () => Promise.resolve(JSON.stringify(response)),
    clone() { return this },
  } as Response
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

    const res = await bulkKeeperDirective(
      [
        { name: 'rondo', ownerGeneration: 3, operatorOperationId: 'resume-rondo-1' },
        { name: 'qa-king', ownerGeneration: 5, operatorOperationId: 'resume-qa-1' },
      ],
      'resume',
    )

    const call = mockFetch.mock.calls[0]!
    const init = call[1] as RequestInit
    expect(call[0]).toBe('/api/v1/keepers_bulk/directive')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      action: 'resume',
      targets: [
        {
          name: 'rondo',
          owner_nonce: 3,
          operator_operation_id: 'resume-rondo-1',
        },
        {
          name: 'qa-king',
          owner_nonce: 5,
          operator_operation_id: 'resume-qa-1',
        },
      ],
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

    const res = await bulkKeeperDirective(
      [
        { name: 'rondo', ownerGeneration: 3, operatorOperationId: 'resume-rondo-2' },
        { name: 'ghost', ownerGeneration: 0, operatorOperationId: 'resume-ghost-1' },
      ],
      'resume',
    )

    expect(res.ok).toBe(true)
    expect(res.succeeded).toBe(1)
    expect(res.results[1]!.ok).toBe(false)
    expect(res.results[1]!.error).toBe('keeper meta not found')
  })

  it('boots each offline keeper whose bulk resume was durably committed', async () => {
    mockFetch
      .mockResolvedValueOnce(mockResponse({
        ok: false,
        action: 'resume',
        requested: 1,
        succeeded: 0,
        results: [
          {
            name: 'offline-rondo',
            ok: false,
            committed: true,
            error: 'live owner missing',
          },
        ],
      }, { status: 202 }))
      .mockResolvedValueOnce(mockResponse({
        ok: true,
        action: 'boot',
        name: 'offline-rondo',
      }))
    vi.stubGlobal('fetch', mockFetch)

    const res = await bulkKeeperDirective(
      [{
        name: 'offline-rondo',
        ownerGeneration: 7,
        operatorOperationId: 'resume-offline-rondo-1',
      }],
      'resume',
    )

    expect(mockFetch).toHaveBeenCalledTimes(2)
    expect(mockFetch.mock.calls[1]![0]).toBe('/api/v1/keepers/offline-rondo/boot')
    expect(res).toMatchObject({
      ok: true,
      succeeded: 1,
      results: [{ name: 'offline-rondo', ok: true, action: 'boot', committed: true }],
    })
  })

  it('reports a committed bulk resume when its follow-up boot fails', async () => {
    mockFetch
      .mockResolvedValueOnce(mockResponse({
        ok: false,
        action: 'resume',
        requested: 1,
        succeeded: 0,
        results: [
          {
            name: 'offline-rondo',
            ok: false,
            committed: true,
            error: 'live owner missing',
          },
        ],
      }, { status: 202 }))
      .mockResolvedValueOnce(mockResponse({
        ok: false,
        action: 'boot',
        name: 'offline-rondo',
        error: 'boot unavailable',
      }, { ok: false, status: 503 }))
    vi.stubGlobal('fetch', mockFetch)

    const res = await bulkKeeperDirective(
      [{
        name: 'offline-rondo',
        ownerGeneration: 7,
        operatorOperationId: 'resume-offline-rondo-2',
      }],
      'resume',
    )

    expect(res).toMatchObject({
      ok: false,
      succeeded: 0,
      results: [{
        name: 'offline-rondo',
        ok: false,
        action: 'boot',
        committed: true,
        error: 'boot unavailable',
      }],
    })
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

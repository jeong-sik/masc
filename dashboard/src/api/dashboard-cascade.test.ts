import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchCascadeClientCapacityHistory,
  fetchCascadeConfig as fetchCascadeConfigFromCascade,
  fetchCascadeStrategyTrace,
  updateKeeperCascade,
} from './dashboard-cascade'
import { fetchCascadeConfig as fetchCascadeConfigFromDashboard } from './dashboard'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('dashboard cascade split', () => {
  it('keeps the dashboard re-export wired to the extracted module', () => {
    expect(fetchCascadeConfigFromDashboard).toBe(fetchCascadeConfigFromCascade)
  })

  it('builds cascade client capacity history query params', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        updated_at: '2026-04-22T00:00:00Z',
        total_events: 0,
        events: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchCascadeClientCapacityHistory({ limit: 50, kind: 'cli' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/cascade/client_capacity/history?limit=50&kind=cli')
    expect(result.total_events).toBe(0)
  })

  it('builds cascade strategy trace query params', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        updated_at: '2026-04-22T00:00:00Z',
        total_events: 0,
        events: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchCascadeStrategyTrace({ limit: 25, cascade: 'big_three' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/cascade/strategy_trace?limit=25&cascade=big_three')
    expect(result.events).toEqual([])
  })

  it('posts keeper cascade updates unchanged', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await updateKeeperCascade('sojin', 'big_three')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keeper/cascade')
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({ method: 'POST' })
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({
      keeper: 'sojin',
      cascade_name: 'big_three',
    }))
    expect(result.ok).toBe(true)
  })
})

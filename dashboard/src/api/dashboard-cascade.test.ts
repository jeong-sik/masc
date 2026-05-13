import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchCascadeAuditRuns,
  fetchCascadeClientCapacityHistory,
  fetchCascadeConfig as fetchCascadeConfigFromCascade,
  fetchCascadeStrategyTrace,
  updateCascadeConfigRaw,
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

  it('builds cascade audit runs query params', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        updated_at: '2026-04-22T00:00:00Z',
        total_runs: 0,
        audit_runs: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchCascadeAuditRuns({ limit: 10, cascade: 'keeper_unified' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/cascade/audit_runs?limit=10&cascade=keeper_unified')
    expect(result.audit_runs).toEqual([])
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

  it('posts cascade source edits as source_text', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        updated_at: '2026-04-22T00:00:00Z',
        source_path: '/tmp/config/cascade.toml',
        validation_status: 'validated',
        validation_errors: [],
        invalid_profiles: [],
        profiles: [],
        keeper_profiles: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const sourceText = [
      '[providers.glm-coding]',
      'protocol = "openai-http"',
      'endpoint = "https://api.z.ai/api/coding/paas/v4"',
      '',
      '[models.glm-auto]',
      'api-name = "glm-5-turbo"',
      'max-context = 128000',
      'tools-support = true',
      '',
      '[glm-coding.glm-auto]',
      'is-default = true',
      'max-concurrent = 2',
      '',
      '[tier.big_three]',
      'members = ["glm-coding.glm-auto"]',
      'strategy = "failover"',
      '',
      '[tier-group.big_three]',
      'tiers = ["big_three"]',
      'strategy = "priority_tier"',
      'fallback = true',
      '',
      '[routes.keeper_turn]',
      'target = "tier-group.big_three"',
      '',
    ].join('\n')

    await updateCascadeConfigRaw(sourceText)

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/cascade/config/raw')
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({ method: 'POST' })
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({
      source_text: sourceText,
    }))
  })
})

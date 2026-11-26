import { describe, expect, it } from 'vitest'
import { parseProviderUsageHistoryResponse } from './provider-usage-history'

// Shaped as server_provider_usage_history_projection.ml response_json writes it.
function history(points: readonly unknown[], extra: Record<string, unknown> = {}) {
  return {
    days: 7,
    generated_at: 1_800_000_000,
    sampling: 'latest_provider_report_per_utc_day',
    unreadable_reports: 2,
    reported_no_windows: [{ scope_id: 'provider:zai', observed_at: 1_799_990_000 }],
    points,
    ...extra,
  }
}

const base = { scope_id: 'provider:claude_one', source: 'anthropic.oauth_usage', kind: 'five_hour', limit_id: null, observed_at: 1_799_999_000, resets_at: 1_800_003_600 }

describe('parseProviderUsageHistoryResponse', () => {
  it('decodes every unit the history writes into its own utilization variant', () => {
    const parsed = parseProviderUsageHistoryResponse(history([
      { ...base, unit: 'fraction', value: 0.4 },
      { ...base, unit: 'percent', value: 100 },
      { ...base, unit: 'usd', value: 3.5, limit: null },
      { ...base, unit: 'credit_balance', currency: 'USD', total: null, remaining: 0 },
      { ...base, unit: 'credit_unlimited', resets_at: null, limit_id: 'weekly' },
    ]))
    if (parsed.state !== 'ready') throw new Error('expected ready')
    expect(parsed.points.map(p => p.utilization)).toEqual([
      { unit: 'fraction', value: 0.4 },
      { unit: 'percent', value: 100 },
      { unit: 'usd', value: 3.5, limit: null },
      { unit: 'credit_balance', currency: 'USD', total: null, remaining: 0 },
      { unit: 'credit_unlimited' },
    ])
    expect(parsed.points[4]).toMatchObject({ resets_at: null, limit_id: 'weekly' })
    expect(parsed.undecodable_points).toBe(0)
    expect(parsed.unreadable_reports).toBe(2)
    expect(parsed.reported_no_windows).toEqual([{ scope_id: 'provider:zai', observed_at: 1_799_990_000 }])
  })

  it('counts a reading it cannot read instead of drawing it as zero use', () => {
    const parsed = parseProviderUsageHistoryResponse(history([
      { ...base, unit: 'fraction', value: 0.4 },
      { ...base, unit: 'fraction' },
      { ...base, unit: 'credit_retracted' },
      { ...base, unit: 'usd', value: 1, limit: 'ten' },
      { ...base, unit: 'percent', value: 5, resets_at: 'soon' },
      { ...base, scope_id: undefined, unit: 'percent', value: 5 },
    ]))
    if (parsed.state !== 'ready') throw new Error('expected ready')
    expect(parsed.points).toHaveLength(1)
    expect(parsed.undecodable_points).toBe(5)
  })

  it('keeps the server unavailable answer and refuses a response that is not the history', () => {
    expect(parseProviderUsageHistoryResponse({ state: 'unavailable', reason: 'store unavailable' }))
      .toEqual({ state: 'unavailable', reason: 'store unavailable' })
    expect(() => parseProviderUsageHistoryResponse({ state: 'unavailable' })).toThrow('reason')
    expect(() => parseProviderUsageHistoryResponse({})).toThrow('days')
    expect(() => parseProviderUsageHistoryResponse(history([], { unreadable_reports: -1 }))).toThrow('unreadable_reports')
    expect(() => parseProviderUsageHistoryResponse(history([], { points: undefined }))).toThrow('points')
    expect(() => parseProviderUsageHistoryResponse(history([], { state: 'ready' }))).toThrow('unknown state')
  })
})

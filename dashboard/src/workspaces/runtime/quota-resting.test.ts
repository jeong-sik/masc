import { describe, expect, it } from 'vitest'
import { partitionQuotaScopes, restingProviderIds, type ProviderUsageScope, type RuntimeResolution } from './types'

function runtime(id: string, provider: string, providerId: string, resting: boolean): RuntimeResolution {
  return {
    id, provider, provider_id: providerId, model: 'm', effective_max_context: 1, max_context_source: 'capability',
    max_output_tokens: null, is_local: false, is_default: false,
    quota_rest: resting ? { cause: 'provider_quota_refused', reset_stated: false, until: 100 } : null,
  }
}

// A subscription scope with room left: only a resting runtime moves it to Tier 1.
const scope: ProviderUsageScope = {
  scope: 'provider:claude_one',
  providers: [{ id: 'claude_one', display_name: 'Claude · one' }],
  state: 'reported',
  windows: [{
    limit_id: null, window: { kind: 'five_hour' },
    utilization: { unit: 'percent', value: 10 }, resets_at: null, observed_at: 1, source: 's', role: 'gates_model_calls',
  }],
}

describe('restingProviderIds', () => {
  it('keys a resting runtime by provider_id, so a scope whose display name differs still reaches Tier 1', () => {
    const ids = restingProviderIds([
      runtime('rt-a', 'Claude · one', 'claude_one', true),
      runtime('rt-b', 'Codex · two', 'codex_two', false),
    ])
    expect([...ids]).toEqual(['claude_one'])
    expect(partitionQuotaScopes([scope], ids).tier1ExhaustedOrCredits).toEqual([scope])
  })

  it('leaves the scope in Tier 2 when no runtime of that provider rests', () => {
    const ids = restingProviderIds([runtime('rt-a', 'Claude · one', 'claude_one', false)])
    expect(ids.size).toBe(0)
    expect(partitionQuotaScopes([scope], ids).tier2ActiveSubscriptions).toEqual([scope])
  })

  it('promotes providers with credential_refused or active rate_limited to Tier 1, but ignores expired rate limits', () => {
    const now = 1_794_500_000
    const refused: RuntimeResolution = {
      ...runtime('rt-refused', 'Claude · one', 'claude_one', false),
      credential_refused_at: now - 30,
    }
    const activeLimited: RuntimeResolution = {
      ...runtime('rt-limited', 'Claude · one', 'claude_one', false),
      rate_limited: true,
      rate_limit_resets_at: now + 60,
    }
    const expiredLimited: RuntimeResolution = {
      ...runtime('rt-expired', 'Claude · one', 'claude_one', false),
      rate_limited: true,
      rate_limit_resets_at: now - 5,
    }

    expect([...restingProviderIds([refused], now)]).toEqual(['claude_one'])
    expect(partitionQuotaScopes([scope], restingProviderIds([refused], now), now).tier1ExhaustedOrCredits).toEqual([scope])

    expect([...restingProviderIds([activeLimited], now)]).toEqual(['claude_one'])
    expect(partitionQuotaScopes([scope], restingProviderIds([activeLimited], now), now).tier1ExhaustedOrCredits).toEqual([scope])

    expect(restingProviderIds([expiredLimited], now).size).toBe(0)
    expect(partitionQuotaScopes([scope], restingProviderIds([expiredLimited], now), now).tier2ActiveSubscriptions).toEqual([scope])
  })
})

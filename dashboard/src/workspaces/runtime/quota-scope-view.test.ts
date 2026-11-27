import { describe, expect, it } from 'vitest'
import {
  aggregateScopeCalls,
  analyzeWindowBurn,
  computeScopeImpact,
  countQuotaFilters,
  decodeRuntimeMetrics24h,
  enrichQuotaScopes,
  filterAndSortQuotaScopes,
  formatDurationKo,
  summarizeScopeHistory,
} from './quota-scope-view'
import type {
  ProviderUsageHistoryResponse,
  ProviderUsageScope,
  ProviderUsageWindow,
  RuntimeAssignment,
  RuntimeLaneSnapshot,
  RuntimeResolution,
  SetupAccountEmail,
} from './types'

const NOW = 1_795_760_000

function makeWindow(overrides: Partial<ProviderUsageWindow> = {}): ProviderUsageWindow {
  return {
    limit_id: null,
    window: { kind: 'five_hour' },
    utilization: { unit: 'fraction', value: 0.4 },
    resets_at: NOW + 3600,
    observed_at: NOW - 60,
    source: 'claude_code.rate_limit_event',
    role: 'gates_model_calls',
    ...overrides,
  }
}

function makeScope(overrides: Partial<ProviderUsageScope> = {}): ProviderUsageScope {
  return {
    scope: 'provider:claude_a',
    scope_id: 'scope-claude-a',
    providers: [{ id: 'claude_a', display_name: 'Claude · A' }],
    state: 'reported',
    windows: [makeWindow()],
    ...overrides,
  }
}

describe('quota-scope-view', () => {
  it('computes elapsed time to exhaustion for a spent 5h window with resets_at', () => {
    // 5h = 18000s. Reset in 3h (10800s) -> window started 2h (7200s) ago.
    // Observed spent 18m (1080s) ago -> elapsed before cutoff = 7200 - 1080 = 6120s (1h 42m).
    const burn = analyzeWindowBurn(
      makeWindow({
        window: { kind: 'five_hour' },
        utilization: { unit: 'fraction', value: 1.0 },
        resets_at: NOW + 10_800,
        observed_at: NOW - 1080,
      }),
      NOW,
    )
    expect(burn.spent).toBe(true)
    expect(burn.durationSec).toBe(18_000)
    expect(burn.windowStartSec).toBe(NOW - 7200)
    expect(burn.elapsedSinceStartSec).toBe(6120)
    expect(formatDurationKo(burn.elapsedSinceStartSec!)).toBe('1시간 42분')
    expect(burn.projectedTotalSec).toBeNull()
  })

  it('computes active burn pace projection only when utilization >= 5% and elapsed >= 60s', () => {
    // 7d = 604800s. Window started 2d (172800s) ago, currently 50% used -> projected 4d (345600s).
    const burn = analyzeWindowBurn(
      makeWindow({
        window: { kind: 'seven_day' },
        utilization: { unit: 'percent', value: 50 },
        resets_at: NOW + 5 * 86_400,
        observed_at: NOW,
      }),
      NOW,
    )
    expect(burn.spent).toBe(false)
    expect(burn.elapsedSinceStartSec).toBe(2 * 86_400)
    expect(burn.projectedTotalSec).toBe(4 * 86_400)
    expect(formatDurationKo(burn.projectedTotalSec!)).toBe('4일')

    const tooEarly = analyzeWindowBurn(
      makeWindow({
        window: { kind: 'five_hour' },
        utilization: { unit: 'percent', value: 2 },
        resets_at: NOW + 17_900,
        observed_at: NOW,
      }),
      NOW,
    )
    expect(tooEarly.projectedTotalSec).toBeNull()
  })

  it('decodes /api/v1/runtime/metrics honestly and aggregates 24h calls per scope', () => {
    expect(decodeRuntimeMetrics24h({}).state).toBe('unavailable')
    expect(decodeRuntimeMetrics24h({ history: { state: 'unavailable', decision_read: { cause: 'directory_unavailable' } } })).toEqual({
      state: 'unavailable',
      reason: 'directory_unavailable',
    })

    const decoded = decodeRuntimeMetrics24h({
      history: {
        state: 'ready',
        window_minutes: 1440,
        observed_at: NOW,
        attributed_entries: 45,
        unattributed_entries: 3,
        runtimes: [
          {
            runtime_id: 'claude_a.sonnet',
            entry_count: 30,
            success_count: 28,
            error_count: 2,
            total_tool_calls: 50,
            total_input_tokens: 120_000,
            total_output_tokens: 10_000,
            total_cache_read_tokens: 90_000,
            total_cost_usd: 0,
            p50_latency_ms: 1200,
            p95_latency_ms: 3400,
          },
          {
            runtime_id: 'claude_a.haiku',
            entry_count: 10,
            success_count: 10,
            error_count: 0,
            total_tool_calls: 8,
            total_input_tokens: 20_000,
            total_output_tokens: 3_000,
            total_cache_read_tokens: null,
            total_cost_usd: null,
            p50_latency_ms: 400,
            p95_latency_ms: 800,
          },
          {
            runtime_id: 'glm.glm-5-4',
            entry_count: 5,
            success_count: 5,
            error_count: 0,
            total_tool_calls: 2,
            total_input_tokens: null,
            total_output_tokens: null,
            total_cache_read_tokens: null,
            total_cost_usd: null,
            p50_latency_ms: 900,
            p95_latency_ms: 1500,
          },
        ],
      },
    })
    expect(decoded.state).toBe('ready')

    const runtimes: RuntimeResolution[] = [
      {
        id: 'claude_a.sonnet',
        provider: 'Claude · A',
        provider_id: 'claude_a',
        model: 'sonnet',
        effective_max_context: 200_000,
        max_context_source: 'capability',
        max_output_tokens: null,
        is_local: false,
        is_default: false,
        quota_rest: null,
      },
    ]
    const summary = aggregateScopeCalls(makeScope(), runtimes, decoded)
    expect(summary).not.toBeNull()
    expect(summary!.calls).toBe(40)
    expect(summary!.success).toBe(38)
    expect(summary!.errors).toBe(2)
    expect(summary!.toolCalls).toBe(58)
    expect(summary!.inputTokens).toBe(140_000)
    expect(summary!.cacheReadTokens).toBe(90_000)
    expect(summary!.runtimes.map((r) => r.runtime_id)).toEqual(['claude_a.sonnet', 'claude_a.haiku'])
  })

  it('summarizes scope history exhausted days and peak utilization', () => {
    const history: ProviderUsageHistoryResponse = {
      state: 'ready',
      days: 14,
      generated_at: NOW,
      sampling: 'latest_provider_report_per_utc_day',
      unreadable_reports: 0,
      reported_no_windows: [],
      undecodable_points: 0,
      points: [
        {
          scope_id: 'scope-claude-a',
          source: 'claude_code.rate_limit_event',
          kind: 'seven_day',
          limit_id: null,
          observed_at: 1_795_500_000,
          resets_at: 1_796_000_000,
          utilization: { unit: 'fraction', value: 0.62 },
        },
        {
          scope_id: 'scope-claude-a',
          source: 'claude_code.rate_limit_event',
          kind: 'seven_day',
          limit_id: null,
          observed_at: 1_795_600_000,
          resets_at: 1_796_000_000,
          utilization: { unit: 'fraction', value: 1.0 },
        },
        {
          scope_id: 'scope-other',
          source: 'zai.quota_limit',
          kind: 'five_hour',
          limit_id: null,
          observed_at: 1_795_600_000,
          resets_at: null,
          utilization: { unit: 'percent', value: 12 },
        },
      ],
    }

    const summary = summarizeScopeHistory(makeScope(), history)
    expect(summary).not.toBeNull()
    expect(summary!.days).toBe(14)
    expect(summary!.observedDays).toBe(2)
    expect(summary!.exhaustedDays).toBe(1)
    expect(summary!.peakPct).toBe(100)
    expect(summary!.points).toHaveLength(2)
  })

  it('filters by group/resting/search and sorts by utilization, reset time, and 24h calls', () => {
    const scopes: ProviderUsageScope[] = [
      makeScope({
        scope: 'provider:claude_exhausted',
        scope_id: 's1',
        providers: [{ id: 'claude_exhausted', display_name: 'Claude · Exhausted' }],
        windows: [makeWindow({ utilization: { unit: 'fraction', value: 1.0 }, resets_at: NOW + 7200 })],
      }),
      makeScope({
        scope: 'provider:codex_b',
        scope_id: 's2',
        providers: [{ id: 'codex_b', display_name: 'Codex · B' }],
        windows: [makeWindow({ utilization: { unit: 'percent', value: 25 }, resets_at: NOW + 1800 })],
      }),
      makeScope({
        scope: 'provider:glm',
        scope_id: 's3',
        providers: [{ id: 'glm', display_name: 'Z.AI GLM' }],
        windows: [makeWindow({ utilization: { unit: 'percent', value: 60 }, resets_at: NOW + 3600 })],
      }),
      makeScope({
        scope: 'provider:vibe',
        scope_id: 's4',
        providers: [{ id: 'vibe', display_name: 'Mistral Vibe' }],
        state: 'not_reported_since_start',
        windows: [],
      }),
    ]
    const metrics24h = decodeRuntimeMetrics24h({
      history: {
        state: 'ready',
        window_minutes: 1440,
        observed_at: NOW,
        attributed_entries: 90,
        unattributed_entries: 0,
        runtimes: [
          { runtime_id: 'glm.glm-5-4', entry_count: 70, success_count: 65, error_count: 5, total_tool_calls: 10 },
          { runtime_id: 'codex_b.gpt', entry_count: 20, success_count: 20, error_count: 0, total_tool_calls: 4 },
        ],
      },
    })
    const lanes: RuntimeLaneSnapshot[] = [
      { id: 'pool-a', declared: true, runtime_ids: ['codex_b.gpt', 'glm.glm-5-4'] },
    ]
    const assignments: RuntimeAssignment[] = [
      { keeper: 'wkbl-data', assignment_source: 'explicit', resolved: { kind: 'lane', id: 'pool-a' } },
    ]
    const runtimes: RuntimeResolution[] = [
      {
        id: 'codex_b.gpt',
        provider: 'Codex · B',
        provider_id: 'codex_b',
        model: 'gpt',
        effective_max_context: 200_000,
        max_context_source: 'capability',
        max_output_tokens: null,
        is_local: false,
        is_default: false,
        quota_rest: null,
      },
    ]
    const accountEmails = new Map<string, SetupAccountEmail>([
      ['codex_b', { integration_id: 'codex_b', state: 'read', email: 'ops-b@example.com', plan: ['plus'] }],
    ])

    const enriched = enrichQuotaScopes({
      scopes,
      restingProviders: new Set(['claude_exhausted']),
      accountEmails,
      runtimes,
      lanes,
      assignments,
      metrics24h,
      history: null,
      nowUnix: NOW,
    })

    expect(countQuotaFilters(enriched)).toEqual({
      all: 4,
      attention: 1,
      healthy_sub: 2,
      resting: 1,
      unreported: 1,
    })

    // Utilization ascending -> lowest utilization (most headroom) first, null last
    expect(
      filterAndSortQuotaScopes(enriched, { filter: 'all', sort: 'util_asc', query: '' }).map((i) => i.primaryProviderId),
    ).toEqual(['codex_b', 'glm', 'claude_exhausted', 'vibe'])

    // Soonest reset first
    expect(
      filterAndSortQuotaScopes(enriched, { filter: 'all', sort: 'reset_soon', query: '' }).map((i) => i.primaryProviderId),
    ).toEqual(['codex_b', 'glm', 'claude_exhausted', 'vibe'])

    // 24h calls descending
    expect(
      filterAndSortQuotaScopes(enriched, { filter: 'all', sort: 'calls_desc', query: '' }).map((i) => i.primaryProviderId),
    ).toEqual(['glm', 'codex_b', 'claude_exhausted', 'vibe'])

    // Search matches account email and impacted keeper name
    expect(
      filterAndSortQuotaScopes(enriched, { filter: 'all', sort: 'default', query: 'ops-b@example' }).map((i) => i.primaryProviderId),
    ).toEqual(['codex_b'])
    expect(
      filterAndSortQuotaScopes(enriched, { filter: 'all', sort: 'default', query: 'wkbl-data' }).map((i) => i.primaryProviderId),
    ).toEqual(['codex_b'])

    // Impact mapping
    const impact = computeScopeImpact(scopes[1]!, runtimes, lanes, assignments)
    expect(impact).toEqual({
      runtimeIds: ['codex_b.gpt'],
      laneIds: ['pool-a'],
      keepers: ['wkbl-data'],
    })
  })
})

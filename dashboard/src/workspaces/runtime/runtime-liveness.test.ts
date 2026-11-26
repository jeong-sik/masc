import { describe, expect, it } from 'vitest'
import { groupRestingRuntimes } from './quota-rest-groups'
import {
  collectRuntimeLiveness,
  runtimeIsAvailable,
  runtimeLivenessBlock,
} from './runtime-liveness'
import type { RuntimeResolution } from './types'

const NOW = 1_794_500_000

function runtime(id: string, extra: Partial<RuntimeResolution> = {}): RuntimeResolution {
  return {
    id,
    provider: 'provider',
    model: `model-${id}`,
    effective_max_context: 128_000,
    max_context_source: 'capability',
    max_output_tokens: null,
    is_local: false,
    is_default: false,
    quota_rest: null,
    ...extra,
  }
}

describe('runtime liveness', () => {
  it('a runtime with credential_refused_at is not shown as available', () => {
    const rt = runtime('refused', { credential_refused_at: NOW - 600, rate_limited: false })
    expect(runtimeLivenessBlock(rt, NOW)).toEqual({ kind: 'credential_refused', since: NOW - 600 })
    expect(runtimeIsAvailable(rt, NOW)).toBe(false)
  })

  it('a rate limit with a future reset blocks until that reset', () => {
    const rt = runtime('limited', { rate_limited: true, rate_limit_resets_at: NOW + 90 })
    expect(runtimeLivenessBlock(rt, NOW)).toEqual({ kind: 'rate_limited', resetsAt: NOW + 90 })
    expect(runtimeIsAvailable(rt, NOW)).toBe(false)
    expect(runtimeIsAvailable(rt, NOW + 91)).toBe(true)
  })

  it('a rate limit without a stated reset blocks until a call succeeds', () => {
    const rt = runtime('limited', { rate_limited: true, rate_limit_resets_at: null })
    expect(runtimeLivenessBlock(rt, NOW)).toEqual({ kind: 'rate_limited', resetsAt: null })
  })

  it('a refused credential wins over a rate limit, as in the TUI', () => {
    const rt = runtime('both', { credential_refused_at: NOW - 5, rate_limited: true, rate_limit_resets_at: NOW + 60 })
    expect(runtimeLivenessBlock(rt, NOW)?.kind).toBe('credential_refused')
  })

  it('a failed attempt is listed but the runtime stays available', () => {
    const failed_attempt = { noted_at: NOW - 30, failure: 'server_error', recorded_by: 'leader' } as const
    const rt = runtime('flaky', { rate_limited: false, failed_attempt })
    expect(runtimeIsAvailable(rt, NOW)).toBe(true)
    expect(collectRuntimeLiveness([rt], NOW)).toEqual([{ runtime: rt, block: null, failedAttempt: failed_attempt }])
  })

  it('a runtime without liveness facts is not listed', () => {
    expect(collectRuntimeLiveness([runtime('quiet'), runtime('ok', { rate_limited: false })], NOW)).toEqual([])
  })

  it('a quota-resting runtime is left to the quota panel unless its credential was refused', () => {
    const quota_rest = { cause: 'usage_read', reset_stated: true, until: NOW + 3600 } as const
    const resting = runtime('resting', { quota_rest, rate_limited: true })
    const restingRefused = runtime('resting-refused', { quota_rest, credential_refused_at: NOW - 60 })
    expect(collectRuntimeLiveness([resting, restingRefused], NOW).map((row) => row.runtime.id))
      .toEqual(['resting-refused'])
  })

  it('the quota summary does not count refused or rate-limited runtimes as available', () => {
    const grouped = groupRestingRuntimes([
      runtime('ok'),
      runtime('refused', { credential_refused_at: NOW - 600 }),
      runtime('limited', { rate_limited: true, rate_limit_resets_at: NOW + 60 }),
      runtime('limit-passed', { rate_limited: true, rate_limit_resets_at: NOW - 1 }),
      runtime('resting', { quota_rest: { cause: 'payment_refused', reset_stated: false, until: NOW + 60 } }),
    ], { sortBy: 'release', causeFilter: 'all', nowUnix: NOW })
    expect(grouped.summary.totalRegistered).toBe(5)
    expect(grouped.summary.restingCount).toBe(1)
    expect(grouped.summary.availableCount).toBe(2)
  })
})

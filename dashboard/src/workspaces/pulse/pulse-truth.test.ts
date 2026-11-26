import { describe, expect, it } from 'vitest'
import { observedValue } from '../../core/resource-cache'
import { GoalSourceUnavailableError } from '../../api/dashboard-goals'
import { decodeApprovals, decodeGoals, decodeProviderUsage } from './pulse-data'
import { buildAttentionQueue, classifySpendStatus, formatApprovalExpiry } from './pulse-model'
import { quotaWindowStanding, summarizeQuotaWindows } from './pulse-quota'
import type { PulseProviderUsagePoint, PulseProviderUsageSnapshot } from './types'

const NOW = 1_700_000_000
const DAY = 86_400

function point(overrides: Partial<PulseProviderUsagePoint> = {}): PulseProviderUsagePoint {
  return {
    scope_id: 'codex',
    source: 'codex_rate_limits',
    kind: '5h',
    limit_id: null,
    observed_at: NOW - 60,
    resets_at: NOW + 3600,
    utilization: { unit: 'fraction', value: 0.4 },
    ...overrides,
  }
}

function usage(points: readonly PulseProviderUsagePoint[], reportedNoWindows: { scope_id: string; observed_at: number }[] = []) {
  const snapshot: PulseProviderUsageSnapshot = {
    state: 'available',
    days: 7,
    points,
    reported_no_windows: reportedNoWindows,
    undecodable_points: 0,
  }
  return observedValue(snapshot)
}

const UNAVAILABLE_QUEUE = {
  state: 'unavailable',
  code: 'reset_required',
  title: 'Gate durable queue unavailable · runtime reset required',
  operator_detail: 'pending.jsonl line 3 unreadable',
  severity: 'bad',
  icon: '!',
}

describe('decodeProviderUsage', () => {
  it('keeps resets_at, observed_at, limit_id and reported_no_windows from the wire', () => {
    const decoded = decodeProviderUsage({
      days: 7,
      sampling: 'latest_provider_report_per_utc_day',
      reported_no_windows: [{ scope_id: 'glm', observed_at: NOW - 10 }],
      points: [
        { scope_id: 'codex', source: 'codex_rate_limits', kind: '5h', limit_id: 'primary', observed_at: NOW - 60, resets_at: NOW + 3600, unit: 'fraction', value: 1 },
        { scope_id: 'or', source: 'openrouter_key_read', kind: 'key', limit_id: null, observed_at: NOW - 60, resets_at: null, unit: 'usd', value: 10, limit: 10 },
      ],
    })
    expect(decoded).toEqual({
      state: 'available',
      days: 7,
      reported_no_windows: [{ scope_id: 'glm', observed_at: NOW - 10 }],
      undecodable_points: 0,
      points: [
        { scope_id: 'codex', source: 'codex_rate_limits', kind: '5h', limit_id: 'primary', observed_at: NOW - 60, resets_at: NOW + 3600, utilization: { unit: 'fraction', value: 1 } },
        { scope_id: 'or', source: 'openrouter_key_read', kind: 'key', limit_id: null, observed_at: NOW - 60, resets_at: null, utilization: { unit: 'usd', value: 10, limit: 10 } },
      ],
    })
  })

  it('counts a point with an unknown unit or no observed_at as undecodable instead of guessing', () => {
    const decoded = decodeProviderUsage({
      days: 1,
      points: [
        { scope_id: 'a', source: 's', kind: 'k', observed_at: NOW, unit: 'tokens', value: 1 },
        { scope_id: 'a', source: 's', kind: 'k', unit: 'fraction', value: 1 },
        { scope_id: 'a', source: 's', kind: 'k', observed_at: NOW, resets_at: 'soon', unit: 'fraction', value: 1 },
      ],
    })
    expect(decoded.state).toBe('available')
    if (decoded.state === 'available') {
      expect(decoded.points).toHaveLength(0)
      expect(decoded.undecodable_points).toBe(3)
    }
  })
})

describe('quota exhaustion against now', () => {
  it('a window that reset yesterday is not exhausted', () => {
    const yesterday = point({ observed_at: NOW - DAY, resets_at: NOW - DAY + 3600, utilization: { unit: 'fraction', value: 1 } })
    expect(quotaWindowStanding(yesterday, NOW).kind).toBe('reset_since_report')
    const quota = summarizeQuotaWindows(usage([yesterday]), NOW)
    expect(quota.exhausted).toBe(0)
    expect(quota.spentResetUnknown).toBe(0)
  })

  it('a window spent on an earlier day does not count when a later reading of it has room', () => {
    const spentEarlier = point({ observed_at: NOW - 2 * DAY, resets_at: NOW + DAY, utilization: { unit: 'percent', value: 100 } })
    const today = point({ observed_at: NOW - 60, resets_at: NOW + DAY, utilization: { unit: 'percent', value: 30 } })
    const quota = summarizeQuotaWindows(usage([spentEarlier, today]), NOW)
    expect(quota.exhausted).toBe(0)
    expect(quota.subscription).toBe(1)
  })

  it('a spent window whose reset is ahead is exhausted and says when it comes back', () => {
    const spent = point({ resets_at: NOW + 7200, utilization: { unit: 'fraction', value: 1 } })
    const quota = summarizeQuotaWindows(usage([spent, point({ kind: '7d', resets_at: NOW + 3600, utilization: { unit: 'percent', value: 100 } })]), NOW)
    expect(quota.exhausted).toBe(2)
    expect(quota.nextReturnAt).toBe(NOW + 3600)
  })

  it('a spent window without resets_at is reported as reset unknown, not exhausted', () => {
    const spent = point({ resets_at: null, utilization: { unit: 'credit_balance', remaining: 0 } })
    expect(quotaWindowStanding(spent, NOW)).toEqual({ kind: 'spent_reset_unknown', observedAt: NOW - 60 })
    const quota = summarizeQuotaWindows(usage([spent]), NOW)
    expect(quota.exhausted).toBe(0)
    expect(quota.spentResetUnknown).toBe(1)
  })

  it('usd at limit is exhausted; usd below or without a limit is not', () => {
    expect(quotaWindowStanding(point({ utilization: { unit: 'usd', value: 25, limit: 25 } }), NOW).kind).toBe('exhausted')
    expect(quotaWindowStanding(point({ utilization: { unit: 'usd', value: 24.99, limit: 25 } }), NOW).kind).toBe('room_left')
    expect(quotaWindowStanding(point({ utilization: { unit: 'usd', value: 1000, limit: null } }), NOW).kind).toBe('no_limit')
  })

  it('uses the server spent thresholds: fraction 1.0 and percent 100', () => {
    expect(quotaWindowStanding(point({ utilization: { unit: 'fraction', value: 0.999 } }), NOW).kind).toBe('room_left')
    expect(quotaWindowStanding(point({ utilization: { unit: 'percent', value: 99 } }), NOW).kind).toBe('room_left')
  })

  it('a later report of the scope that stated no window drops the earlier spent reading', () => {
    const spent = point({ observed_at: NOW - DAY, resets_at: NOW + DAY, utilization: { unit: 'fraction', value: 1 } })
    const quota = summarizeQuotaWindows(usage([spent], [{ scope_id: 'codex', observed_at: NOW - 60 }]), NOW)
    expect(quota.exhausted).toBe(0)
  })

  it('classifies $0 as Exhausted only while the reset is still ahead', () => {
    const costs = observedValue([
      { keeper_name: 'k', total_cost_usd: null, cost_reported_samples: 0, cost_unreported_samples: 3, total_tokens: 1, sample_count: 3 },
    ])
    const spentUntilLater = usage([point({ resets_at: NOW + 600, utilization: { unit: 'fraction', value: 1 } })])
    expect(classifySpendStatus(costs, spentUntilLater, 0, NOW).kind).toBe('exhausted_zero')
    expect(classifySpendStatus(costs, spentUntilLater, 0, NOW + 601).kind).toBe('subscription_zero')
  })
})

describe('decodeGoals', () => {
  it('an unavailable approval queue is not zero approvals', () => {
    const decoded = decodeGoals({ generated_at: 'x', approval_queue_state: UNAVAILABLE_QUEUE, tree: null, summary: null })
    expect(decoded).toEqual({
      state: 'approval_queue_unavailable',
      title: UNAVAILABLE_QUEUE.title,
      detail: UNAVAILABLE_QUEUE.operator_detail,
    })
  })

  it('rejects a response without a readable approval_queue_state', () => {
    expect(() => decodeGoals({ tree: [] })).toThrow()
  })

  it('throws the goal source failure instead of reading it as an empty list', () => {
    expect(() => decodeGoals({ ok: false, error_code: 'goal_task_links_unavailable', error: 'links unreadable' }))
      .toThrow(GoalSourceUnavailableError)
  })

  it('counts sub-goal pending approvals into the parent row', () => {
    const decoded = decodeGoals({
      approval_queue_state: { state: 'ready' },
      summary: { pending_approvals: 3 },
      tree: [{
        id: 'g-1', title: 'Parent', phase: 'Executing', pending_approval_count: 1,
        children: [{
          id: 'g-2', title: 'Child', phase: 'Executing', pending_approval_count: 0,
          children: [{ id: 'g-3', title: 'Grandchild', phase: 'Executing', pending_approval_count: 2, children: [] }],
        }],
      }],
    })
    expect(decoded.state).toBe('ready')
    if (decoded.state === 'ready') {
      expect(decoded.pending_approval_total).toBe(3)
      expect(decoded.goals).toHaveLength(1)
      expect(decoded.goals[0]!.pending_approval_count).toBe(3)
      expect(decoded.goals[0]!.sub_goal_count).toBe(2)
    }
  })

  it('keeps a missing phase as unknown instead of Executing', () => {
    const decoded = decodeGoals({ approval_queue_state: { state: 'ready' }, tree: [{ id: 'g-1', title: 'No phase' }] })
    expect(decoded.state === 'ready' && decoded.goals[0]!.phase).toBeNull()
  })
})

describe('tool approvals', () => {
  it('decodes because and timeout_sec, and an empty because as null', () => {
    const decoded = decodeApprovals({
      pending: [
        { keeper: 'k', tool_call_id: 'tc', approval_id: 'ap', tool: 'bash', args: '{}', question: 'Run?', because: 'writes outside sandbox', asked_at: NOW - 30, timeout_sec: 300 },
        { keeper: 'k', tool_call_id: 'tc2', approval_id: 'ap2', tool: 'bash', args: '{}', question: 'Run?', because: '', asked_at: NOW - 30 },
      ],
    })
    expect(decoded.map((d) => [d.because, d.timeout_sec])).toEqual([['writes outside sandbox', 300], [null, null]])
  })

  it('shows why a call was held and when it times out', () => {
    const [item] = buildAttentionQueue({
      approvals: [{ approval_id: 'ap', keeper: 'k', tool_call_id: 'tc', tool: 'bash', question: 'Run?', because: 'writes outside sandbox', asked_at: NOW - 30, timeout_sec: 300 }],
      asks: [],
      keepers: [],
      nowSec: NOW,
    })
    expect(item!.detail).toContain('writes outside sandbox')
    expect(item!.expiresInSec).toBe(270)
    expect(formatApprovalExpiry(-5)).toBe('만료 시각 지남')
  })

  it('leaves the timeout unknown when asked_at or timeout_sec is missing', () => {
    const [item] = buildAttentionQueue({
      approvals: [{ approval_id: 'ap', keeper: 'k', tool_call_id: 'tc', tool: 'bash', question: 'Run?', because: null, asked_at: NOW - 30, timeout_sec: null }],
      asks: [],
      keepers: [],
      nowSec: NOW,
    })
    expect(item!.expiresInSec).toBeNull()
    expect(item!.detail).toBe('Run?')
  })
})

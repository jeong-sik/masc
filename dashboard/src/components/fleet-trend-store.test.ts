import { describe, it, expect, beforeEach } from 'vitest'
import { pushSnapshot, getTrend, resetTrendStore } from './fleet-trend-store'
import type { FleetRow } from './fleet-telemetry-utils'

function makeRow(name: string, overrides: Partial<FleetRow> = {}): FleetRow {
  return {
    name,
    status: 'active',
    keepalive_running: true,
    context_ratio: 0.5,
    turn_count: 0,
    last_latency_ms: 100,
    last_activity_ago_s: 10,
    activity_label: '최근 활동',
    activity_source: 'last_activity',
    model: 'test-model',
    tool_calls: 5,
    tool_success_pct: 95,
    tool_activity_known: true,
    recent_tools: [],
    runtime_blocker_class: null,
    runtime_blocker_summary: null,
    tool_audit_at: null,
    goal_label: null,
    goal_linked: false,
    active_goal_count: 0,
    sandbox_profile: null,
    sandbox_last_error: null,
    effective_sandbox_image: null,
    decision_required: false,
    budget_source: null,
    ...overrides,
  }
}

describe('fleet-trend-store', () => {
  beforeEach(() => {
    resetTrendStore()
  })

  it('returns null when fewer than 3 snapshots exist', () => {
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.1 })])
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.2 })])
    expect(getTrend('keeper-a', 'context_ratio')).toBeNull()
  })

  it('detects upward trend', () => {
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.1 })])
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.2 })])
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.3 })])
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.4 })])
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.5 })])
    pushSnapshot([makeRow('keeper-a', { context_ratio: 0.6 })])

    const trend = getTrend('keeper-a', 'context_ratio')
    expect(trend?.direction).toBe('up')
    expect(trend?.delta).toBeGreaterThan(0)
  })

  it('detects downward trend', () => {
    for (const v of [100, 90, 80, 70, 60, 50]) {
      pushSnapshot([makeRow('keeper-a', { last_latency_ms: v })])
    }
    const trend = getTrend('keeper-a', 'last_latency_ms')
    expect(trend?.direction).toBe('down')
    expect(trend?.delta).toBeLessThan(0)
  })

  it('detects flat trend when values are stable', () => {
    for (let i = 0; i < 6; i += 1) {
      pushSnapshot([makeRow('keeper-a', { tool_calls: 5 })])
    }
    const trend = getTrend('keeper-a', 'tool_calls')
    expect(trend?.direction).toBe('flat')
  })

  it('caps ring buffer at 10 snapshots', () => {
    for (let i = 0; i < 20; i += 1) {
      pushSnapshot([makeRow('keeper-a', { tool_calls: i })])
    }
    const trend = getTrend('keeper-a', 'tool_calls')
    expect(trend?.values.length).toBe(10)
    expect(trend?.values[0]).toBe(10)
    expect(trend?.values[9]).toBe(19)
  })

  it('isolates trends per keeper', () => {
    for (let i = 0; i < 5; i += 1) {
      pushSnapshot([
        makeRow('keeper-a', { context_ratio: 0.1 + i * 0.1 }),
        makeRow('keeper-b', { context_ratio: 0.9 - i * 0.1 }),
      ])
    }
    expect(getTrend('keeper-a', 'context_ratio')?.direction).toBe('up')
    expect(getTrend('keeper-b', 'context_ratio')?.direction).toBe('down')
  })

  it('skips null tool_success_pct values', () => {
    pushSnapshot([makeRow('keeper-a', { tool_success_pct: null })])
    pushSnapshot([makeRow('keeper-a', { tool_success_pct: null })])
    pushSnapshot([makeRow('keeper-a', { tool_success_pct: null })])
    expect(getTrend('keeper-a', 'tool_success_pct')).toBeNull()
  })

  it('resetTrendStore clears all data', () => {
    for (let i = 0; i < 5; i += 1) {
      pushSnapshot([makeRow('keeper-a', { context_ratio: i * 0.1 })])
    }
    expect(getTrend('keeper-a', 'context_ratio')).not.toBeNull()
    resetTrendStore()
    expect(getTrend('keeper-a', 'context_ratio')).toBeNull()
  })
})

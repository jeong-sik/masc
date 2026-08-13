import { describe, expect, it } from 'vitest'

import { projectDashboardCompositeHealth } from './dashboard-composite-health'

describe('projectDashboardCompositeHealth', () => {
  it('preserves missing backend health as unavailable', () => {
    expect(projectDashboardCompositeHealth(null)).toEqual({
      state: 'unavailable',
      issueCount: 0,
      issues: [],
    })
  })

  it('reports healthy only from an explicit fresh backend verdict', () => {
    expect(projectDashboardCompositeHealth({
      overall_status: 'ok',
      operator_action_required: false,
      full_health_snapshot: {
        status: 'ready',
        stale_reason: null,
        last_good_available: true,
        component_timed_out: false,
      },
    })).toEqual({ state: 'healthy', issueCount: 0, issues: [] })
  })

  it('never suppresses an explicit backend action requirement', () => {
    const result = projectDashboardCompositeHealth({
      overall_status: 'degraded',
      operator_action_required: true,
      operator_action_reasons: ['keeper_event_queue'],
      full_health_snapshot: {
        status: 'stale',
        stale_reason: 'refresh_failed',
        last_good_available: true,
        component_timed_out: false,
      },
    })

    expect(result).toMatchObject({
      state: 'attention',
      severity: 'warn',
      issueCount: 1,
    })
    expect(result.issues[0]?.detail).toContain('keeper_event_queue')
  })

  it('never projects a timed-out component as healthy', () => {
    expect(projectDashboardCompositeHealth({
      overall_status: 'ok',
      operator_action_required: false,
      full_health_snapshot: {
        status: 'ready',
        stale_reason: null,
        last_good_available: true,
        component_timed_out: true,
      },
    })).toMatchObject({
      state: 'status',
      severity: 'bad',
      issueCount: 0,
    })
  })
})

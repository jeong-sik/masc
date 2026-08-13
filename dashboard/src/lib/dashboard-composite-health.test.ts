import { describe, expect, it } from 'vitest'
import { LIVE_OVERVIEW_COMPOSITE_HEALTH } from '../testing/dashboard-composite-health-fixture'
import { projectDashboardCompositeHealth } from './dashboard-composite-health'

describe('projectDashboardCompositeHealth', () => {
  it('preserves the live degraded backend composite as one operator item', () => {
    expect(projectDashboardCompositeHealth(LIVE_OVERVIEW_COMPOSITE_HEALTH)).toEqual({
      state: 'attention',
      severity: 'warn',
      issueCount: 1,
      issues: [
        {
          kind: 'runtime-health',
          severity: 'warn',
          label: 'Runtime health degraded',
          detail: 'status=degraded · keeper_fleet_safety · keeper_reaction_ledger · keeper_event_queue',
        },
      ],
    })
  })

  it('does not fabricate healthy when the composite projection is absent', () => {
    expect(projectDashboardCompositeHealth(null)).toEqual({
      state: 'unavailable',
      issueCount: 0,
      issues: [],
    })
  })

  it('returns healthy only when every reported backend verdict is healthy', () => {
    const fixture = {
      overall_status: 'ok',
      operator_action_required: false,
      operator_action_reasons: [],
    }

    expect(projectDashboardCompositeHealth(fixture)).toEqual({
      state: 'healthy',
      issueCount: 0,
      issues: [],
    })
  })
})

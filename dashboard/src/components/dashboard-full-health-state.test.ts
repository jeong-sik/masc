import { afterEach, describe, expect, it } from 'vitest'

import type { DashboardFullHealthResponse } from '../api/dashboard'
import {
  dashboardFullHealth,
  dashboardFullHealthResource,
} from './dashboard-full-health-state'

const health = {
  overall_status: 'degraded',
  operator_action_required: true,
  operator_action_reasons: ['keeper_event_queue'],
} as DashboardFullHealthResponse

describe('dashboardFullHealth', () => {
  afterEach(() => dashboardFullHealthResource.reset())

  it('retains the last backend verdict while its replacement is loading', () => {
    dashboardFullHealthResource.state.value = {
      data: health,
      loading: true,
      error: null,
    }

    expect(dashboardFullHealth.value).toBe(health)
  })

  it('retains the last backend verdict after a transient refresh failure', () => {
    dashboardFullHealthResource.state.value = {
      data: health,
      loading: false,
      error: 'network down',
    }

    expect(dashboardFullHealth.value).toBe(health)
  })

  it('keeps never-observed health unavailable', () => {
    dashboardFullHealthResource.state.value = {
      data: null,
      loading: true,
      error: null,
    }

    expect(dashboardFullHealth.value).toBeNull()
  })
})

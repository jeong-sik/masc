import { describe, expect, it } from 'vitest'

import { dashboardSlicesForRoute } from './dashboard-ws'

describe('dashboardSlicesForRoute', () => {
  it('keeps global shell namespace and transport slices on every route', () => {
    expect(dashboardSlicesForRoute({ tab: 'overview', params: {} })).toEqual([
      'namespace',
      'shell',
      'transport',
    ])
  })

  it('subscribes execution for execution-heavy monitoring and planning routes', () => {
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'planning' } }))
      .toContain('execution')
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'observatory' } }))
      .toContain('execution')
    expect(dashboardSlicesForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'comparison' },
    })).toContain('execution')
  })

  it('subscribes operator only for the active command surface', () => {
    expect(dashboardSlicesForRoute({ tab: 'command', params: {} })).toContain('operator')
    expect(dashboardSlicesForRoute({ tab: 'command', params: { view: 'inspector' } }))
      .not.toContain('operator')
  })
})

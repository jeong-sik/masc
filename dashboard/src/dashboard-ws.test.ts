import { describe, expect, it } from 'vitest'

import { dashboardSlicesForRoute, parseWebSocketSseFrames } from './dashboard-ws'

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

  it('subscribes route-local dashboard slices for board, goals, and fleet FSM routes', () => {
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'board' } }))
      .toContain('board')
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'planning' } }))
      .toContain('goals')
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'agents' } }))
      .toContain('composite')
  })

  it('subscribes operator only for the active command surface', () => {
    expect(dashboardSlicesForRoute({ tab: 'command', params: {} })).toContain('operator')
    expect(dashboardSlicesForRoute({ tab: 'command', params: { view: 'inspector' } }))
      .not.toContain('operator')
  })
})

describe('parseWebSocketSseFrames', () => {
  it('extracts JSON payloads from raw SSE frames forwarded over websocket', () => {
    expect(parseWebSocketSseFrames([
      'id: 1',
      'data: {"type":"post_created","post_id":"p1"}',
      '',
      'id: 2',
      'event: message',
      'data: {"type":"keeper_composite_changed","name":"qa-king"}',
      '',
      '',
    ].join('\n'))).toEqual([
      { type: 'post_created', post_id: 'p1' },
      { type: 'keeper_composite_changed', name: 'qa-king' },
    ])
  })
})

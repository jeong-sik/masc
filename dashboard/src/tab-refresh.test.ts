import { describe, expect, it, vi } from 'vitest'

vi.mock('./store', () => ({
  refreshShell: vi.fn(),
  refreshExecution: vi.fn(),
  refreshBoard: vi.fn(),
  refreshGoals: vi.fn(),
}))

vi.mock('./room-truth-store', () => ({
  requestRoomTruth: vi.fn(),
}))

vi.mock('./operator-store', () => ({
  refreshOperatorRoomDigest: vi.fn(),
  refreshOperatorSnapshot: vi.fn(),
}))

vi.mock('./mission-store', () => ({
  refreshMissionSnapshot: vi.fn(),
}))

vi.mock('./command-store', () => ({
  commandPlaneSurface: { value: 'overview' },
  refreshCommandPlaneChainSummary: vi.fn(),
  refreshCommandPlaneCurrentSurface: vi.fn(),
  refreshCommandPlaneOrchestra: vi.fn(),
  refreshCommandPlaneSwarm: vi.fn(),
}))

import { refreshPlanForRoute } from './tab-refresh'

describe('refreshPlanForRoute', () => {
  it('hydrates overview from room truth and mission snapshot', () => {
    expect(refreshPlanForRoute({
      tab: 'overview',
      params: {},
    })).toEqual(['shell', 'roomTruth', 'missionSnapshot'])
  })

  it('uses the current monitoring sections', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'agents' },
    })).toEqual(['roomTruth', 'execution', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'activity' },
    })).toEqual(['execution', 'activityGraph'])
  })

  it('uses the current command sections', () => {
    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'intervene' },
    })).toEqual(['roomTruth', 'operatorSnapshot', 'operatorRoomDigest'])

    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'governance' },
    })).toEqual(['roomTruth', 'governance'])
  })

  it('refreshes the new workspace and lab sections only where store-backed data is needed', () => {
    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: { section: 'planning' },
    })).toEqual(['goals', 'execution'])

    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: { section: 'board' },
    })).toEqual(['board'])

    expect(refreshPlanForRoute({
      tab: 'lab',
      params: { section: 'autoresearch' },
    })).toEqual(['autoresearch'])

    expect(refreshPlanForRoute({
      tab: 'lab',
      params: { section: 'harness' },
    })).toEqual(['harness'])

    expect(refreshPlanForRoute({
      tab: 'lab',
      params: { section: 'tools' },
    })).toEqual([])
  })
})

import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./store')>()
  return {
    ...actual,
    refreshShell: vi.fn(),
    refreshExecution: vi.fn(),
    refreshBoard: vi.fn(),
    refreshGoals: vi.fn(),
  }
})

vi.mock('./namespace-truth-store', () => ({
  requestNamespaceTruth: vi.fn(),
}))

vi.mock('./mission-store', () => ({
  refreshMissionSnapshot: vi.fn(),
}))

vi.mock('./components/tool-quality-panel', () => ({
  refreshToolQuality: vi.fn(),
}))

vi.mock('./components/feature-health', () => ({
  refreshFeatureHealth: vi.fn(),
}))

vi.mock('./components/server-config', () => ({
  refreshServerConfig: vi.fn(),
}))

vi.mock('./command-store', () => ({
  commandPlaneSurface: { value: 'overview' },
  refreshCommandPlaneChainSummary: vi.fn(),
  refreshCommandPlaneCurrentSurface: vi.fn(),
}))

import { refreshFeatureHealth } from './components/feature-health'
import { refreshServerConfig } from './components/server-config'
import { refreshShell } from './store'
import { refreshForRoute, refreshPlanForRoute } from './tab-refresh'

const flushDynamicImports = async () => {
  await Promise.resolve()
  await Promise.resolve()
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('refreshPlanForRoute', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('hydrates overview from namespace truth and mission snapshot', () => {
    expect(refreshPlanForRoute({
      tab: 'overview',
      params: {},
    })).toEqual(['shell', 'namespaceTruth', 'missionSnapshot'])
  })

  it('uses the current monitoring sections', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'agents' },
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'activity' },
    })).toEqual(['execution', 'activityGraph'])
  })

  it('keeps the hidden command surface hydrated for ops queue deep links', () => {
    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'intervene' },
    })).toEqual(['namespaceTruth', 'operatorSnapshot', 'operatorRoomDigest'])

    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'governance' },
    })).toEqual(['namespaceTruth', 'operatorSnapshot', 'operatorRoomDigest'])
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
      params: { section: 'tool-quality' },
    })).toEqual(['toolQuality'])

    expect(refreshPlanForRoute({
      tab: 'lab',
      params: { section: 'tools' },
    })).toEqual([])
  })

  it('refreshes the inspector shell through server config once', async () => {
    vi.mocked(refreshServerConfig).mockImplementation(async () => {
      await refreshShell({ force: true })
    })

    refreshForRoute({
      tab: 'lab',
      params: { section: 'inspector' },
    })

    await flushDynamicImports()

    expect(refreshFeatureHealth).toHaveBeenCalledTimes(1)
    expect(refreshServerConfig).toHaveBeenCalledTimes(1)
    expect(refreshShell).toHaveBeenCalledTimes(1)
    expect(refreshShell).toHaveBeenCalledWith({ force: true })
  })
})

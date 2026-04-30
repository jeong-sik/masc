import { waitFor } from '@testing-library/preact'
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

vi.mock('./components/observatory/observatory', () => ({
  refreshObservatorySurface: vi.fn(),
}))

vi.mock('./components/activity-graph-store', () => ({
  refreshActivityGraph: vi.fn(),
}))

vi.mock('./components/git-graph-store', () => ({
  refreshGitGraph: vi.fn(),
}))

import { refreshFeatureHealth } from './components/feature-health'
import { refreshActivityGraph } from './components/activity-graph-store'
import { refreshGitGraph } from './components/git-graph-store'
import { refreshObservatorySurface } from './components/observatory/observatory'
import { refreshServerConfig } from './components/server-config'
import { refreshForRoute, refreshPlanForRoute } from './tab-refresh'
import { refreshExecution, refreshShell } from './store'

describe('refreshPlanForRoute', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('hydrates overview from project snapshot and mission snapshot', () => {
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
      params: { section: 'journey' },
    })).toEqual(['execution', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'observatory' },
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot', 'observatory', 'activityGraph'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'git-graph' },
    })).toEqual(['gitGraph'])
  })

  it('keeps the consolidated command surface hydrated for ops queue deep links', () => {
    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'operations' },
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
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'tool-quality' },
    })).toEqual(['toolQuality'])

    expect(refreshPlanForRoute({
      tab: 'lab',
      params: { section: 'tools' },
    })).toEqual([])
  })

  it('refreshes the inspector shell through server config once (Phase 6: view param)', async () => {
    refreshForRoute({
      tab: 'command',
      params: { section: 'operations', view: 'inspector' },
    })

    await waitFor(() => {
      expect(refreshFeatureHealth).toHaveBeenCalledTimes(1)
      expect(refreshServerConfig).toHaveBeenCalledTimes(1)
    })
  })

  it('refreshes observatory by triggering both the track fetch and activity-derived panels', async () => {
    refreshForRoute({
      tab: 'monitoring',
      params: { section: 'observatory' },
    })

    await waitFor(() => {
      expect(refreshObservatorySurface).toHaveBeenCalledTimes(1)
      expect(refreshActivityGraph).toHaveBeenCalledTimes(1)
    })
  })

  it('refreshes the Git graph surface on route entry', async () => {
    refreshForRoute({
      tab: 'monitoring',
      params: { section: 'git-graph' },
    })

    await waitFor(() => {
      expect(refreshGitGraph).toHaveBeenCalledTimes(1)
    })
  })

  it('uses the budgeted shell refresh path on overview navigation', () => {
    refreshForRoute({
      tab: 'overview',
      params: {},
    })

    expect(refreshShell).toHaveBeenCalledWith({ light: true })
  })

  it('uses the scheduler-backed execution refresh path on monitoring navigation', () => {
    refreshForRoute({
      tab: 'monitoring',
      params: { section: 'journey' },
    })

    expect(refreshExecution).toHaveBeenCalledWith()
  })
})

// -----------------------------------------------------------------------------
// Fleet Health view-aware refresh — Phase 1 active
//
// Fleet Health absorbs telemetry + tool-quality + fleet + governance (monitoring).
// The refresh pipeline branches on the `view` query param so SSE reconnect
// (sse-store.ts:232) and manual navigation hydrate the correct data.
// -----------------------------------------------------------------------------
describe('refreshPlanForRoute fleet-health view-aware branching', () => {
  it('default view (no view param) hydrates general monitoring data', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health' },
    })).toEqual(['namespaceTruth'])
  })

  it('view=event-log hydrates general monitoring data', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'event-log' },
    })).toEqual(['namespaceTruth'])
  })

  it('view=governance avoids mission and operator-heavy route refreshes', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'governance' },
    })).toEqual(['namespaceTruth'])
  })

  it('view=tool-quality routes to the existing refreshToolQuality API', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'tool-quality' },
    })).toEqual(['toolQuality'])
  })

  it('view=comparison hydrates fleet comparison rows', () => {
    const plan = refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'comparison' },
    })
    expect(plan).toContain('execution')
    expect(plan).toContain('toolQuality')
  })
})

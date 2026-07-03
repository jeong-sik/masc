import { waitFor } from '@testing-library/preact'
import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./store')>()
  return {
    ...actual,
    refreshShell: vi.fn(),
    refreshExecution: vi.fn(),
    refreshBoard: vi.fn(),
    refreshFusionBoard: vi.fn(),
    refreshFusionRuns: vi.fn(),
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

vi.mock('./components/surface-readiness-panel', () => ({
  refreshSurfaceReadiness: vi.fn(),
}))

vi.mock('./components/observatory/observatory', () => ({
  refreshObservatorySurface: vi.fn(),
}))

vi.mock('./keeper-runtime', () => ({
  refreshActiveKeeperChatHistory: vi.fn(),
}))

import { refreshFeatureHealth } from './components/feature-health'
import { refreshObservatorySurface } from './components/observatory/observatory'
import { refreshActiveKeeperChatHistory } from './keeper-runtime'
import { refreshServerConfig } from './components/server-config'
import { refreshSurfaceReadiness } from './components/surface-readiness-panel'
import { refreshForRoute, refreshPlanForRoute } from './tab-refresh'
import { refreshExecution, refreshFusionBoard, refreshFusionRuns, refreshShell } from './store'

describe('refreshPlanForRoute', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('hydrates overview from project snapshot and mission snapshot', () => {
    expect(refreshPlanForRoute({
      tab: 'overview',
      params: {},
    })).toEqual(['shell', 'namespaceTruth', 'missionSnapshot', 'execution'])
  })

  it('hydrates the top-level keepers workspace from live execution state', () => {
    expect(refreshPlanForRoute({
      tab: 'keepers',
      params: { keeper: 'sangsu' },
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot', 'activeKeeperChat'])
  })

  it('hydrates the top-level board surface from the board store', () => {
    expect(refreshPlanForRoute({
      tab: 'board',
      params: {},
    })).toEqual(['board'])
  })

  it('hydrates Fusion from its own board-sink source and the registry source', () => {
    expect(refreshPlanForRoute({
      tab: 'fusion',
      params: {},
    })).toEqual(['fusionBoard', 'fusionRuns'])
  })

  it('uses the current monitoring sections', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: {},
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'agents' },
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'journey' },
    })).toEqual(['execution'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'cognition' },
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'observatory' },
    })).toEqual(['namespaceTruth', 'observatory'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'observatory', view: 'activity' },
    })).toEqual(['namespaceTruth', 'observatory'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'observatory', view: 'live' },
    })).toEqual(['namespaceTruth', 'observatory'])
  })

  it('keeps the consolidated command surface hydrated for ops queue deep links', () => {
    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'operations' },
    })).toEqual(['namespaceTruth', 'operatorSnapshot', 'operatorWorkspaceDigest'])

    expect(refreshPlanForRoute({
      tab: 'command',
      params: { section: 'operations', view: 'surfaces' },
    })).toEqual(['surfaceReadiness'])
  })

  it('refreshes the new workspace and lab sections only where store-backed data is needed', () => {
    // The default Work board (section: 'work') reads the same flat goals + tasks
    // signals as planning, so it must fetch both. Regression guard: a missing
    // 'work' branch left the board empty (0 goals / 0 jobs) despite live data.
    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: { section: 'work' },
    })).toEqual(['goals', 'execution'])

    // Bare workspace route normalizes to the 'work' default section.
    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: {},
    })).toEqual(['goals', 'execution'])

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

  it('hydrates the Code IDE route from live execution state', () => {
    expect(refreshPlanForRoute({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
    })).toEqual(['namespaceTruth', 'execution', 'missionSnapshot'])
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

  it('refreshes the surface readiness view on route entry', async () => {
    refreshForRoute({
      tab: 'command',
      params: { section: 'operations', view: 'surfaces' },
    })

    await waitFor(() => {
      expect(refreshSurfaceReadiness).toHaveBeenCalledTimes(1)
    })
  })

  it('refreshes observatory by triggering the timeline track fetch only', async () => {
    refreshForRoute({
      tab: 'monitoring',
      params: { section: 'observatory' },
    })

    await waitFor(() => {
      expect(refreshObservatorySurface).toHaveBeenCalledTimes(1)
    })
  })

  it('keeps retired observatory lens routes on the unified observatory surface', async () => {
    refreshForRoute({
      tab: 'monitoring',
      params: { section: 'observatory', view: 'activity' },
    })

    await waitFor(() => {
      expect(refreshObservatorySurface).toHaveBeenCalledTimes(1)
    })
  })

  it('uses the budgeted shell refresh path on overview navigation', () => {
    refreshForRoute({
      tab: 'overview',
      params: {},
    })

    expect(refreshShell).toHaveBeenCalledWith({ light: true })
  })

  it('requests overview execution immediately without forcing a backend recompute', () => {
    refreshForRoute({
      tab: 'overview',
      params: {},
    })

    expect(refreshExecution).toHaveBeenCalledWith({ immediate: true })
  })

  it('uses the scheduler-backed execution refresh path on monitoring navigation', () => {
    refreshForRoute({
      tab: 'monitoring',
      params: { section: 'journey' },
    })

    expect(refreshExecution).toHaveBeenCalledWith()
  })

  it('uses the scheduler-backed execution refresh path on Code IDE navigation', () => {
    refreshForRoute({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
    })

    expect(refreshExecution).toHaveBeenCalledWith()
  })

  it('uses the scheduler-backed execution refresh path on Keepers navigation', () => {
    refreshForRoute({
      tab: 'keepers',
      params: { keeper: 'sangsu' },
    })

    expect(refreshExecution).toHaveBeenCalledWith()
  })

  it('re-hydrates the open keeper chat on Keepers navigation', async () => {
    refreshForRoute({
      tab: 'keepers',
      params: { keeper: 'sangsu' },
    })

    await waitFor(() => {
      expect(refreshActiveKeeperChatHistory).toHaveBeenCalledTimes(1)
    })
    // Route/periodic refresh must not force (guard-respecting no-op).
    expect(refreshActiveKeeperChatHistory).toHaveBeenCalledWith()
  })

  it('refreshes Fusion without inheriting Board route filters', async () => {
    refreshForRoute({
      tab: 'fusion',
      params: {},
    })

    await waitFor(() => {
      expect(refreshFusionBoard).toHaveBeenCalledTimes(1)
      expect(refreshFusionRuns).toHaveBeenCalledTimes(1)
    })
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
  it('default Tool Monitor board stays light; mounted board owns tool polling', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health' },
    })).toEqual(['namespaceTruth'])
  })

  it('view=event-log keeps route refresh light; mounted evidence log owns polling', () => {
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

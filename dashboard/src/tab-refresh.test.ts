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

vi.mock('./keeper-runtime', () => ({
  refreshActiveKeeperChatHistory: vi.fn(),
}))

import { refreshActiveKeeperChatHistory } from './keeper-runtime'
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
    })).toEqual(['shell', 'namespaceTruth', 'missionSnapshot', 'execution', 'goals'])
  })

  // The overview 작업·목표 card reads the flat `goals` signal. Only the `goals`
  // refresher populates it, so leaving it out of the overview plan made a fresh
  // #overview load print "활성 목표 없음" against a live 15-goal planning store.
  it('includes the goals refresher so the overview goal card has a source', () => {
    expect(refreshPlanForRoute({
      tab: 'overview',
      params: {},
    })).toContain('goals')
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
    })).toEqual(['namespaceTruth', 'missionSnapshot'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'runtime' },
    })).toEqual(['namespaceTruth', 'missionSnapshot'])
  })

  it('refreshes the workspace sections only where store-backed data is needed', () => {
    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: { section: 'work' },
    })).toEqual(['goals', 'execution'])

    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: {},
    })).toEqual(['goals', 'execution'])

    expect(refreshPlanForRoute({
      tab: 'workspace',
      params: { section: 'board' },
    })).toEqual(['board'])

    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'tool-quality' },
    })).toEqual(['toolQuality'])
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
// Fleet Health absorbs telemetry + tool-quality + fleet + Gate monitoring.
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

  it('view=gate avoids mission and operator-heavy route refreshes', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'gate' },
    })).toEqual(['namespaceTruth'])
  })

  it('view=tool-quality routes to the existing refreshToolQuality API', () => {
    expect(refreshPlanForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'tool-quality' },
    })).toEqual(['toolQuality'])
  })
})

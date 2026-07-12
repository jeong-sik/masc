import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DashboardToolsResponse } from '../../api'

const {
  fetchDashboardTools,
  queueRefreshRegistration,
  setupVisibleAutoRefresh,
  stopRefresh,
} = vi.hoisted(() => ({
  fetchDashboardTools: vi.fn<(options?: unknown) => Promise<DashboardToolsResponse>>(
    async () => ({
      tool_inventory: { count: 0, tools: [] },
      tool_usage: {
        total_calls: 0,
        distinct_tools_called: 0,
        top_20: [],
        never_called_count: 0,
        dispatch_v2_enabled: false,
        registered_count: 0,
      },
    }),
  ),
  queueRefreshRegistration: {
    current: null as ((expectedRevisions: ReadonlyMap<string, number>) => void) | null,
  },
  setupVisibleAutoRefresh: vi.fn(),
  stopRefresh: vi.fn(),
}))

setupVisibleAutoRefresh.mockReturnValue(stopRefresh)

vi.mock('../../api', () => ({ fetchDashboardTools }))
vi.mock('../../lib/auto-refresh', () => ({ setupVisibleAutoRefresh }))
vi.mock('../../sse-store', () => ({
  registerKeeperChatQueueRefresh: vi.fn(
    (callback: (expectedRevisions: ReadonlyMap<string, number>) => void) => {
      queueRefreshRegistration.current = callback
    },
  ),
}))

import {
  loadTools,
  subscribeToolsAutoRefresh,
  toolsData,
  toolsError,
  toolsLoading,
} from './tool-state'

function toolsProjection(revision: number): DashboardToolsResponse {
  return {
    tool_inventory: { tools: [] },
    tool_usage: {
      total_calls: 0,
      distinct_tools_called: 0,
      top_20: [],
      never_called_count: 0,
      dispatch_v2_enabled: false,
      registered_count: 0,
    },
    keeper_waiting_inventory: {
      keepers: [{
        keeper_name: 'echo',
        chat_queue: { revision },
      }],
    },
  } as unknown as DashboardToolsResponse
}

let disposers: Array<() => void> = []

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  vi.clearAllMocks()
  setupVisibleAutoRefresh.mockReturnValue(stopRefresh)
})

describe('subscribeToolsAutoRefresh', () => {
  it('shares one polling owner across multiple mounted consumers', async () => {
    const first = subscribeToolsAutoRefresh()
    const second = subscribeToolsAutoRefresh()
    disposers = [first, second]

    expect(setupVisibleAutoRefresh).toHaveBeenCalledTimes(1)
    await vi.waitFor(() => {
      expect(toolsLoading.value).toBe(false)
    })

    first()
    disposers = [second]
    expect(stopRefresh).not.toHaveBeenCalled()

    second()
    disposers = []
    expect(stopRefresh).toHaveBeenCalledTimes(1)
  })

  it('revalidates a cached snapshot whenever the first subscriber mounts', async () => {
    const first = subscribeToolsAutoRefresh()
    disposers = [first]
    await vi.waitFor(() => {
      expect(fetchDashboardTools).toHaveBeenCalledTimes(1)
    })
    await vi.waitFor(() => {
      expect(toolsLoading.value).toBe(false)
    })
    first()
    disposers = []

    const second = subscribeToolsAutoRefresh()
    disposers = [second]
    await vi.waitFor(() => {
      expect(fetchDashboardTools).toHaveBeenCalledTimes(2)
    })
  })

  it('rejects a stale queue invalidation response and keeps requesting the fresh path until revision convergence', async () => {
    fetchDashboardTools.mockResolvedValueOnce(toolsProjection(4))
    await loadTools()
    expect(toolsData.value?.keeper_waiting_inventory?.keepers[0]?.chat_queue.revision).toBe(4)

    fetchDashboardTools.mockResolvedValueOnce(toolsProjection(4))
    queueRefreshRegistration.current?.(new Map([['echo', 5]]))
    await vi.waitFor(() => {
      expect(toolsError.value).toContain('expected revision 5, observed 4')
    })
    expect(toolsData.value?.keeper_waiting_inventory?.keepers[0]?.chat_queue.revision).toBe(4)
    expect(fetchDashboardTools).toHaveBeenLastCalledWith(expect.objectContaining({
      freshKeeperChatQueue: true,
    }))

    fetchDashboardTools.mockResolvedValueOnce(toolsProjection(5))
    await loadTools()
    expect(toolsError.value).toBeNull()
    expect(toolsData.value?.keeper_waiting_inventory?.keepers[0]?.chat_queue.revision).toBe(5)

    fetchDashboardTools.mockResolvedValueOnce(toolsProjection(5))
    await loadTools()
    expect(fetchDashboardTools).toHaveBeenLastCalledWith(expect.objectContaining({
      freshKeeperChatQueue: false,
    }))
  })
})

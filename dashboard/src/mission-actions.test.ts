import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardMission: vi.fn(),
  fetchDashboardMissionBriefing: vi.fn(),
  fetchDashboardMissionSession: vi.fn(),
}))

vi.mock('./api', () => apiMocks)
vi.mock('./api/dashboard', () => apiMocks)
vi.mock('./api/dashboard-mission', () => apiMocks)

const missionPayload = {
  generated_at: '2026-03-25T09:00:00Z',
  summary: {
    workspace_health: 'ok',
    namespace: 'default',
  },
  incidents: [],
  recommended_actions: [],
  command_focus: {},
  operator_targets: {
    keepers: [],
    available_actions: [],
  },
  attention_queue: [],
  attention_read_error: null,
  agent_briefs: [
    {
      agent_name: 'agent-1',
      with_whom: [],
      related_attention_count: 0,
    },
  ],
  keeper_briefs: [
    {
      name: 'keeper-1',
    },
  ],
  internal_signals: [],
}

const initializingMissionPayload = {
  generated_at: '2026-03-25T09:05:00Z',
  summary: {
    workspace_health: 'initializing',
  },
  incidents: [],
  recommended_actions: [],
  command_focus: {},
  operator_targets: {},
  attention_queue: [],
  attention_read_error: null,
  agent_briefs: [],
  keeper_briefs: [],
  internal_signals: [],
}

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('refreshMissionSnapshot', () => {
  it('publishes failed attention reads during initialization and clears the error on recovery', async () => {
    apiMocks.fetchDashboardMission
      .mockResolvedValueOnce(missionPayload)
      .mockResolvedValueOnce({
        ...initializingMissionPayload,
        attention_read_error: 'Attention store unavailable',
      })
      .mockResolvedValueOnce(missionPayload)

    const missionActions = await import('./mission-actions')
    const missionStore = await import('./mission-store')
    await missionActions.refreshMissionSnapshot({ force: true })
    expect(missionStore.missionError.value).toBeNull()
    expect(missionStore.missionSnapshot.value?.summary.workspace_health).toBe('ok')

    await missionActions.refreshMissionSnapshot({ force: true })
    expect(missionStore.missionError.value).toBe('Attention store unavailable')
    expect(missionStore.missionSnapshot.value?.attention_read_error).toBe('Attention store unavailable')
    expect(missionStore.missionSnapshot.value?.summary.workspace_health).toBe('initializing')
    expect(missionStore.missionSnapshot.value?.generated_at).toBe(initializingMissionPayload.generated_at)

    await missionActions.refreshMissionSnapshot({ force: true })
    expect(missionStore.missionError.value).toBeNull()
    expect(missionStore.missionSnapshot.value?.attention_read_error).toBeNull()
    expect(missionStore.missionSnapshot.value?.summary.workspace_health).toBe('ok')
    expect(missionStore.missionSnapshot.value?.keeper_briefs).toHaveLength(1)
  })

  it('requests the mission endpoint without extra query flags', async () => {
    apiMocks.fetchDashboardMission.mockResolvedValue(missionPayload)

    const missionActions = await import('./mission-actions')
    const missionStore = await import('./mission-store')

    missionStore.missionSnapshot.value = null

    await missionActions.refreshMissionSnapshot({ force: true })

    const mission = missionStore.missionSnapshot.value as
      | {
          summary?: { workspace_health?: string | null }
          agent_briefs?: unknown[]
        }
      | null
    expect(apiMocks.fetchDashboardMission).toHaveBeenCalledWith()
    expect(mission?.summary?.workspace_health).toBe('ok')
    expect(mission?.agent_briefs).toHaveLength(1)
  })

  it('keeps the existing mission data when the cached mission is still initializing', async () => {
    apiMocks.fetchDashboardMission
      .mockResolvedValueOnce(missionPayload)
      .mockResolvedValueOnce(initializingMissionPayload)

    const missionActions = await import('./mission-actions')
    const missionStore = await import('./mission-store')

    await missionActions.refreshMissionSnapshot({ force: true })
    await missionActions.refreshMissionSnapshot({ force: true })

    const mission = missionStore.missionSnapshot.value as
      | {
          summary?: { workspace_health?: string | null }
          keeper_briefs?: unknown[]
        }
      | null
    expect(mission?.summary?.workspace_health).toBe('ok')
    expect(mission?.keeper_briefs).toHaveLength(1)
  })
}, 20000)

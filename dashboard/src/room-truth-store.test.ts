import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardRoomTruth: vi.fn(),
  fetchDashboardShell: vi.fn(),
  fetchDashboardExecution: vi.fn(),
  fetchDashboardMemory: vi.fn(),
  fetchDashboardPlanning: vi.fn(),
}))

vi.mock('./api', () => apiMocks)

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('refreshRoomTruth', () => {
  it('hydrates build identity into serverStatus from room truth', async () => {
    apiMocks.fetchDashboardRoomTruth.mockResolvedValue({
      generated_at: '2026-03-25T08:16:21Z',
      room: {
        status: {
          room: 'default',
          current_room: 'default',
          version: '2.148.0',
          build: {
            release_version: '2.148.0',
            commit: '2897da06',
            started_at: '2026-03-25T08:05:54Z',
            uptime_seconds: 588,
          },
        },
        counts: {
          agents: 0,
          tasks: 1,
          keepers: 3,
        },
      },
    })

    const roomTruthStore = await import('./room-truth-store')
    const store = await import('./store')

    store.serverStatus.value = null

    await roomTruthStore.refreshRoomTruth({ force: true })

    const roomStatus = roomTruthStore.roomTruth.value?.room.status as
      | { build?: { commit?: string | null } }
      | undefined
    const mergedBuild = store.serverStatus.value as
      | {
          build?: {
            release_version: string
            commit?: string | null
            started_at: string
            uptime_seconds: number
          }
        }
      | null
    expect(roomStatus?.build?.commit).toBe('2897da06')
    expect(mergedBuild?.build).toEqual({
      release_version: '2.148.0',
      commit: '2897da06',
      started_at: '2026-03-25T08:05:54Z',
      uptime_seconds: 588,
    })
  }, 20000)

  it('normalizes latest meta-cognition digest from room truth', async () => {
    apiMocks.fetchDashboardRoomTruth.mockResolvedValue({
      generated_at: '2026-03-25T08:16:21Z',
      room: {
        status: {
          room: 'default',
          current_room: 'default',
          version: '2.148.0',
        },
      },
      meta_cognition: {
        summary: {
          stagnation_score: 0.72,
          belief_count: 2,
          contested_belief_count: 1,
        },
        latest_digest: {
          post_id: 'post-meta-1',
          title: '[meta-cognition] contested belief requires follow-up',
          created_at: '2026-03-25T08:14:00Z',
          updated_at: '2026-03-25T08:14:00Z',
          hearth: 'meta-cognition',
          digest_key: 'digest-1',
          matches_summary: true,
          provenance: 'board',
        },
      },
    })

    const roomTruthStore = await import('./room-truth-store')

    await roomTruthStore.refreshRoomTruth({ force: true })

    expect(roomTruthStore.roomTruth.value?.meta_cognition?.latest_digest).toEqual({
      post_id: 'post-meta-1',
      title: '[meta-cognition] contested belief requires follow-up',
      created_at: '2026-03-25T08:14:00Z',
      updated_at: '2026-03-25T08:14:00Z',
      hearth: 'meta-cognition',
      digest_key: 'digest-1',
      matches_summary: true,
      provenance: 'board',
    })
  }, 20000)
})

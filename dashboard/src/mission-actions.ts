import { isAbortError } from './lib/async-state'
import {
  missionSnapshot,
  missionLoading,
  missionError,
  missionBriefing,
  missionBriefingLoading,
  missionBriefingError,
  missionSessionDetail,
  missionSessionDetailLoading,
  missionSessionDetailError,
  clearMissionBriefingPoll,
  scheduleMissionBriefingPoll,
} from './mission-signals'
import {
  normalizeMission,
  normalizeMissionSessionDetail,
  normalizeMissionBriefing,
} from './mission-normalizers'
import type { DashboardMissionResponse } from './types'

let inflightMissionSnapshotRefresh: Promise<void> | null = null
let lastMissionSnapshotRefreshAt = 0

const MISSION_TTL_MS = 3_000

interface MissionRefreshOptions {
  force?: boolean
}

function isMissionInitializingPayload(value: DashboardMissionResponse): boolean {
  return (
    value.summary.room_health === 'initializing'
    && value.sessions.length === 0
    && value.agent_briefs.length === 0
    && value.keeper_briefs.length === 0
    && value.attention_queue.length === 0
    && value.internal_signals.length === 0
  )
}

export async function refreshMissionSnapshot(
  opts?: MissionRefreshOptions,
): Promise<void> {
  if (inflightMissionSnapshotRefresh) return inflightMissionSnapshotRefresh
  if (!opts?.force && Date.now() - lastMissionSnapshotRefreshAt < MISSION_TTL_MS) {
    return
  }
  missionLoading.value = true
  missionError.value = null
  inflightMissionSnapshotRefresh = (async () => {
    try {
      const { fetchDashboardMission } = await import('./api/dashboard')
      const raw = await fetchDashboardMission()
      const normalized = normalizeMission(raw)
      if (isMissionInitializingPayload(normalized) && missionSnapshot.value) {
        lastMissionSnapshotRefreshAt = Date.now()
        return
      }
      missionSnapshot.value = normalized
      lastMissionSnapshotRefreshAt = Date.now()
    } catch (err) {
      missionError.value = err instanceof Error ? err.message : 'Failed to load mission snapshot'
    } finally {
      missionLoading.value = false
      inflightMissionSnapshotRefresh = null
    }
  })()
  return inflightMissionSnapshotRefresh
}

export async function refreshMissionSessionDetail(
  sessionId: string | null | undefined,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  if (!sessionId) {
    missionSessionDetail.value = null
    missionSessionDetailError.value = null
    missionSessionDetailLoading.value = false
    return
  }
  missionSessionDetailLoading.value = true
  missionSessionDetailError.value = null
  try {
    const { fetchDashboardMissionSession } = await import('./api/dashboard')
    const raw = await fetchDashboardMissionSession(sessionId, { signal: opts?.signal })
    if (opts?.signal?.aborted) return
    missionSessionDetail.value = normalizeMissionSessionDetail(raw)
  } catch (err) {
    if (isAbortError(err)) return
    missionSessionDetailError.value = err instanceof Error ? err.message : 'Failed to load session detail'
  } finally {
    if (!opts?.signal?.aborted) {
      missionSessionDetailLoading.value = false
    }
  }
}

export async function refreshMissionBriefing(
  force = false,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  missionBriefingLoading.value = true
  missionBriefingError.value = null
  try {
    const { fetchDashboardMissionBriefing } = await import('./api/dashboard')
    const raw = await fetchDashboardMissionBriefing(force, { signal: opts?.signal })
    if (opts?.signal?.aborted) return
    const normalized = normalizeMissionBriefing(raw)
    missionBriefing.value = normalized
    if (normalized.refreshing || normalized.status === 'pending') {
      scheduleMissionBriefingPoll(refreshMissionBriefing)
    } else {
      clearMissionBriefingPoll()
    }
  } catch (err) {
    if (isAbortError(err)) return
    missionBriefingError.value = err instanceof Error ? err.message : 'Failed to load mission briefing'
    clearMissionBriefingPoll()
  } finally {
    if (!opts?.signal?.aborted) {
      missionBriefingLoading.value = false
    }
  }
}

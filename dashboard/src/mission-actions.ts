import { isAbortError } from './lib/async-state'
import { errorMessageOr } from './lib/format-string'
import {
  missionSnapshot,
  missionLoading,
  missionError,
  missionBriefing,
  missionBriefingLoading,
  missionBriefingError,
  clearMissionBriefingPoll,
  scheduleMissionBriefingPoll,
} from './mission-signals'
import {
  normalizeMission,
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
    value.summary.workspace_health === 'initializing'
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
      const { fetchDashboardMission } = await import('./api/dashboard-mission')
      const raw = await fetchDashboardMission()
      const normalized = normalizeMission(raw)
      if (isMissionInitializingPayload(normalized) && missionSnapshot.value) {
        lastMissionSnapshotRefreshAt = Date.now()
        return
      }
      missionSnapshot.value = normalized
      lastMissionSnapshotRefreshAt = Date.now()
    } catch (err) {
      missionError.value = errorMessageOr(err, 'Failed to load mission snapshot')
    } finally {
      missionLoading.value = false
      inflightMissionSnapshotRefresh = null
    }
  })()
  return inflightMissionSnapshotRefresh
}

export async function refreshMissionBriefing(
  force = false,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  missionBriefingLoading.value = true
  missionBriefingError.value = null
  try {
    const { fetchDashboardMissionBriefing } = await import('./api/dashboard-mission')
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
    missionBriefingError.value = errorMessageOr(err, 'Failed to load mission briefing')
    clearMissionBriefingPoll()
  } finally {
    if (!opts?.signal?.aborted) {
      missionBriefingLoading.value = false
    }
  }
}

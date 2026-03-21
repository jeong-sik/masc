import {
  fetchDashboardMission,
  fetchDashboardMissionBriefing,
  fetchDashboardMissionSession,
} from './api'
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

export async function refreshMissionSnapshot(): Promise<void> {
  missionLoading.value = true
  missionError.value = null
  try {
    const raw = await fetchDashboardMission()
    missionSnapshot.value = normalizeMission(raw)
  } catch (err) {
    missionError.value = err instanceof Error ? err.message : 'Failed to load mission snapshot'
  } finally {
    missionLoading.value = false
  }
}

export async function refreshMissionSessionDetail(sessionId: string | null | undefined): Promise<void> {
  if (!sessionId) {
    missionSessionDetail.value = null
    missionSessionDetailError.value = null
    missionSessionDetailLoading.value = false
    return
  }
  missionSessionDetailLoading.value = true
  missionSessionDetailError.value = null
  try {
    const raw = await fetchDashboardMissionSession(sessionId)
    missionSessionDetail.value = normalizeMissionSessionDetail(raw)
  } catch (err) {
    missionSessionDetailError.value = err instanceof Error ? err.message : 'Failed to load session detail'
  } finally {
    missionSessionDetailLoading.value = false
  }
}

export async function refreshMissionBriefing(force = false): Promise<void> {
  missionBriefingLoading.value = true
  missionBriefingError.value = null
  try {
    const raw = await fetchDashboardMissionBriefing(force)
    const normalized = normalizeMissionBriefing(raw)
    missionBriefing.value = normalized
    if (normalized.refreshing || normalized.status === 'pending') {
      scheduleMissionBriefingPoll(refreshMissionBriefing)
    } else {
      clearMissionBriefingPoll()
    }
  } catch (err) {
    missionBriefingError.value = err instanceof Error ? err.message : 'Failed to load mission briefing'
    clearMissionBriefingPoll()
  } finally {
    missionBriefingLoading.value = false
  }
}

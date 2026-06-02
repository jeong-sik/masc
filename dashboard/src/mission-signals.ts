import { signal, computed, type ReadonlySignal } from '@preact/signals'
import { MISSION_BRIEFING_POLL_DELAY_MS } from './config/constants'
import type {
  DashboardMissionBriefingResponse,
  DashboardMissionResponse,
  DashboardMissionSessionDetailResponse,
  DashboardMissionAgentBrief,
  DashboardMissionKeeperBrief,
} from './types'

export const missionSnapshot = signal<DashboardMissionResponse | null>(null)

// Fine-grained computed signals to avoid full re-render on every snapshot update.
// Components that only need briefs subscribe to these instead of missionSnapshot.
export const missionAgentBriefs: ReadonlySignal<DashboardMissionAgentBrief[]> = computed(
  () => missionSnapshot.value?.agent_briefs ?? []
)
export const missionKeeperBriefs: ReadonlySignal<DashboardMissionKeeperBrief[]> = computed(
  () => missionSnapshot.value?.keeper_briefs ?? []
)
export const missionLoading = signal(false)
export const missionError = signal<string | null>(null)
export const missionBriefing = signal<DashboardMissionBriefingResponse | null>(null)
export const missionBriefingLoading = signal(false)
export const missionBriefingError = signal<string | null>(null)
export const missionSessionDetail = signal<DashboardMissionSessionDetailResponse | null>(null)
export const missionSessionDetailLoading = signal(false)
export const missionSessionDetailError = signal<string | null>(null)

let missionBriefingPollTimer: number | null = null

export function clearMissionBriefingPoll(): void {
  if (missionBriefingPollTimer !== null) {
    window.clearTimeout(missionBriefingPollTimer)
    missionBriefingPollTimer = null
  }
}

export function scheduleMissionBriefingPoll(
  refreshFn: (force: boolean) => Promise<void>,
  delayMs = MISSION_BRIEFING_POLL_DELAY_MS,
): void {
  if (missionBriefingPollTimer !== null) return
  missionBriefingPollTimer = window.setTimeout(() => {
    missionBriefingPollTimer = null
    void refreshFn(false)
  }, delayMs)
}

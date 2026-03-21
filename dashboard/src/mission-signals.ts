import { signal } from '@preact/signals'
import type {
  DashboardMissionBriefingResponse,
  DashboardMissionResponse,
  DashboardMissionSessionDetailResponse,
} from './types'

export const missionSnapshot = signal<DashboardMissionResponse | null>(null)
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

export function scheduleMissionBriefingPoll(refreshFn: (force: boolean) => Promise<void>, delayMs = 1500): void {
  if (missionBriefingPollTimer !== null) return
  missionBriefingPollTimer = window.setTimeout(() => {
    missionBriefingPollTimer = null
    void refreshFn(false)
  }, delayMs)
}

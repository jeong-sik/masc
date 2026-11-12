import { signal, computed, type ReadonlySignal } from '@preact/signals'
import type {
  DashboardMissionResponse,
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
export const missionInitializing = signal(false)

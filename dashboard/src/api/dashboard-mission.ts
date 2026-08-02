// MASC Dashboard — mission/briefing/planning fetchers.
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { get } from './core'
import type {
  DashboardMissionResponse,
  DashboardMissionBriefingResponse,
  DashboardPlanningResponse,
} from '../types'

export function fetchDashboardBriefing(): Promise<DashboardMissionResponse> {
  return get('/api/v1/dashboard/briefing')
}

export function fetchDashboardMission(): Promise<DashboardMissionResponse> {
  return fetchDashboardBriefing()
}

export function fetchDashboardMissionBriefing(
  force = false,
  opts?: { signal?: AbortSignal },
): Promise<DashboardMissionBriefingResponse> {
  const query = force ? '?force=1' : ''
  return get(`/api/v1/dashboard/briefing/sections${query}`, { signal: opts?.signal })
}

export function fetchDashboardPlanning(): Promise<DashboardPlanningResponse> {
  return get('/api/v1/dashboard/planning')
}

import { post } from './core'

// Schedule-only mutation boundary. Gate/HITL transport lives in dashboard-gate.ts.

export interface DashboardSchedulePruneResponse {
  ok: boolean
  pruned_count: number
}

export function pruneSchedules(): Promise<DashboardSchedulePruneResponse> {
  return post('/api/v1/dashboard/schedule/prune', {})
}

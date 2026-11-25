import { authSession, resolveWorkspaceUrl } from '../core/auth'
import { apiMutate } from '../core/transport'
import { post } from './core'

// Schedule-only mutation boundary. Gate/HITL transport lives in dashboard-gate.ts.

export interface DashboardSchedulePruneResponse {
  ok: boolean
  pruned_count: number
}

export async function pruneSchedules(): Promise<DashboardSchedulePruneResponse> {
  const path = '/api/v1/dashboard/schedule/prune'
  if (authSession.peek().kind !== 'multi_account_signed_in') {
    return post(resolveWorkspaceUrl(path), {})
  }
  const result = await apiMutate<DashboardSchedulePruneResponse>('POST', path, {})
  if (!result.ok) throw new Error(result.error.message)
  return result.value
}

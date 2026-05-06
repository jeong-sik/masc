import { get } from './core'
import {
  normalizeGoalLoopStatus,
  type GoalLoopStatusResponse,
} from '../goal-loop-status'

export function fetchGoalLoopStatus(opts?: {
  signal?: AbortSignal
}): Promise<GoalLoopStatusResponse> {
  return get<unknown>('/api/v1/dashboard/goal-loop/status', { signal: opts?.signal })
    .then(normalizeGoalLoopStatus)
}

import type { KeeperApprovalQueueState } from '../types'
import { isRecord } from './type-guards'

export function decodeKeeperApprovalQueueState(
  raw: unknown,
): Exclude<KeeperApprovalQueueState, { state: 'observation_error' }> | null {
  if (!isRecord(raw)) return null
  if (raw.state === 'ready' && Object.keys(raw).length === 1) {
    return { state: 'ready' }
  }
  if (
    raw.state === 'unavailable'
    && raw.code === 'reset_required'
    && typeof raw.title === 'string'
    && raw.title.trim() !== ''
    && typeof raw.operator_detail === 'string'
    && raw.operator_detail.trim() !== ''
    && raw.severity === 'bad'
    && raw.icon === '!'
    && Object.keys(raw).length === 6
  ) {
    return {
      state: 'unavailable',
      code: 'reset_required',
      title: raw.title.trim(),
      operator_detail: raw.operator_detail.trim(),
      severity: 'bad',
      icon: '!',
    }
  }
  return null
}

export function approvalQueueProblem(
  state: KeeperApprovalQueueState | null | undefined,
): Exclude<KeeperApprovalQueueState, { state: 'ready' }> | null {
  if (!state) return null
  switch (state.state) {
    case 'ready': return null
    case 'unavailable':
    case 'observation_error': return state
  }
}

type GateObservationErrorState = Extract<
  KeeperApprovalQueueState,
  { state: 'observation_error' }
>

export function gateObservationErrorState(
  detail: string,
): GateObservationErrorState {
  return {
    state: 'observation_error',
    code: 'observation_failed',
    title: 'Gate observation unavailable',
    operator_detail: detail.trim() || 'Gate observation failed',
    severity: 'bad',
    icon: '!',
  }
}

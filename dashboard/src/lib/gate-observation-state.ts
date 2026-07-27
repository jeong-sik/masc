import type { KeeperApprovalQueueState } from '../types'

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

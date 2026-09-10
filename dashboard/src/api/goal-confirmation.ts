import { get, post } from './core'
import { decodeGoalProof } from './goal-proof'
import { isRecord } from '../components/common/normalize'
import type { GoalProofCompletion } from '../types/core'

type Proven = Extract<GoalProofCompletion, { state: 'proven' }>
export interface GoalConfirmationEvidence {
  goalId: string
  phase: string
  proof: Proven
}
export interface GoalConfirmationBinding {
  goal_id: string
  criterion_revision: string
  request_id: string
  verification_run_id: string
}

export function decodeConfirmation(raw: unknown, goalId: string): GoalConfirmationEvidence {
  if (!isRecord(raw) || !isRecord(raw.goal) || raw.goal.id !== goalId || typeof raw.goal.phase !== 'string')
    throw new Error('목표 확인 응답의 식별자가 일치하지 않습니다')
  if (!isRecord(raw.verification) || raw.verification.goal_id !== goalId)
    throw new Error('verifier 증거의 목표 식별자가 일치하지 않습니다')
  const decoded = decodeGoalProof(raw.verification)
  if (decoded.state !== 'current' || decoded.completion.state !== 'proven')
    throw new Error('현재 기준에 대한 verifier 증명을 확인할 수 없습니다')
  if (raw.goal.criterion_revision !== decoded.completion.criterion.revision)
    throw new Error('목표 기준과 verifier 증명의 revision이 다릅니다')
  return { goalId, phase: raw.goal.phase, proof: decoded.completion }
}

export function confirmationBinding(evidence: GoalConfirmationEvidence): GoalConfirmationBinding {
  return { goal_id: evidence.goalId, criterion_revision: evidence.proof.criterion.revision,
    request_id: evidence.proof.requestId, verification_run_id: evidence.proof.runId }
}
export function sameConfirmationBinding(evidence: GoalConfirmationEvidence, binding: GoalConfirmationBinding): boolean {
  const current = confirmationBinding(evidence)
  return current.goal_id === binding.goal_id && current.criterion_revision === binding.criterion_revision
    && current.request_id === binding.request_id && current.verification_run_id === binding.verification_run_id
}
export async function readGoalConfirmation(goalId: string): Promise<GoalConfirmationEvidence> {
  return decodeConfirmation(await get<unknown>(`/api/v1/goals/confirmation?goal_id=${encodeURIComponent(goalId)}`), goalId)
}
export async function submitGoalConfirmation(binding: GoalConfirmationBinding): Promise<GoalConfirmationEvidence> {
  return decodeConfirmation(await post<unknown>('/api/v1/goals/confirmation', binding), binding.goal_id)
}

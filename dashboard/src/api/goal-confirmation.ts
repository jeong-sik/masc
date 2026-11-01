import { getWithResponse, post } from './core'
import { artifactWorkspaceBody, artifactWorkspaceQuery, requireArtifactWorkspaceRead, type ArtifactWorkspace } from './published-artifacts'
import { decodeGoalProof } from './goal-proof'
import { isRecord } from '../components/common/normalize'
import type { GoalProofCompletion, GoalProofCriterion } from '../types/core'

type Proven = Extract<GoalProofCompletion, { state: 'proven' }>
export interface GoalConfirmationEvidence {
  goalId: string
  phase: string
  proof: Proven
  workspace: ArtifactWorkspace
  inspectionOperatorId: string
  authorityKind: 'system_llm_agent' | 'human_operator'
}
export interface GoalConfirmationBinding {
  goal_id: string
  criterion_revision: string
  request_id: string
  verification_run_id: string
  expected_workspace: { base_path: string; masc_root: string }
  expected_operator_id: string
  criterion: GoalProofCriterion
  observedProof: Proven
  observedAuthorityKind: 'system_llm_agent' | 'human_operator'
}

export function decodeConfirmation(raw: unknown, goalId: string, workspace: ArtifactWorkspace): GoalConfirmationEvidence {
  if (!isRecord(raw) || typeof raw.inspection_operator_id !== 'string' || raw.inspection_operator_id.trim() === '')
    throw new Error('증거를 조회한 운영자를 확인할 수 없습니다')
  if (!isRecord(raw) || !isRecord(raw.goal) || raw.goal.id !== goalId || typeof raw.goal.phase !== 'string')
    throw new Error('목표 확인 응답의 식별자가 일치하지 않습니다')
  if (!isRecord(raw.verification) || raw.verification.goal_id !== goalId)
    throw new Error('verifier 증거의 목표 식별자가 일치하지 않습니다')
  const decoded = decodeGoalProof(raw.verification)
  if (decoded.state !== 'current' || decoded.completion.state !== 'proven')
    throw new Error('현재 기준에 대한 verifier 증명을 확인할 수 없습니다')
  const completion = raw.verification.completion
  const verdict = isRecord(completion) ? completion.verdict : null
  const authority = isRecord(verdict) ? verdict.authority : null
  if (!isRecord(authority) || (authority.kind !== 'system_llm_agent' && authority.kind !== 'human_operator'))
    throw new Error('verifier 증명의 권한을 확인할 수 없습니다')
  const criterion = decoded.completion.criterion
  if (raw.goal.criterion_revision !== criterion.revision || raw.goal.title !== criterion.title
    || raw.goal.metric !== criterion.metric || raw.goal.target_value !== criterion.target_value)
    throw new Error('목표 기준과 verifier 증명의 내용이 다릅니다')
  return { goalId, phase: raw.goal.phase, proof: decoded.completion, workspace, inspectionOperatorId: raw.inspection_operator_id,
    authorityKind: authority.kind }
}

export function confirmationBinding(evidence: GoalConfirmationEvidence): GoalConfirmationBinding {
  return { goal_id: evidence.goalId, criterion_revision: evidence.proof.criterion.revision,
    request_id: evidence.proof.requestId, verification_run_id: evidence.proof.runId,
    expected_workspace: artifactWorkspaceBody(evidence.workspace), expected_operator_id: evidence.inspectionOperatorId,
    criterion: evidence.proof.criterion, observedProof: evidence.proof, observedAuthorityKind: evidence.authorityKind }
}
export function sameConfirmationBinding(evidence: GoalConfirmationEvidence, binding: GoalConfirmationBinding): boolean {
  const current = confirmationBinding(evidence)
  return current.goal_id === binding.goal_id && current.criterion_revision === binding.criterion_revision
    && current.request_id === binding.request_id && current.verification_run_id === binding.verification_run_id
    && current.expected_workspace.base_path === binding.expected_workspace.base_path
    && current.expected_workspace.masc_root === binding.expected_workspace.masc_root
    && current.expected_operator_id === binding.expected_operator_id
    && current.criterion.revision === binding.criterion.revision && current.criterion.title === binding.criterion.title
    && current.criterion.metric === binding.criterion.metric && current.criterion.target_value === binding.criterion.target_value
    && current.observedProof.evidence === binding.observedProof.evidence
    && current.observedProof.actor === binding.observedProof.actor
    && current.observedProof.recordedAt === binding.observedProof.recordedAt
    && current.observedAuthorityKind === binding.observedAuthorityKind
}
export async function readGoalConfirmation(goalId: string, workspace: ArtifactWorkspace): Promise<GoalConfirmationEvidence> {
  const query = artifactWorkspaceQuery(workspace)
  query.set('goal_id', goalId)
  const result = await getWithResponse<unknown>(`/api/v1/goals/confirmation?${query}`, { consumeWithinTimeout: true })
  requireArtifactWorkspaceRead(result.headers)
  return decodeConfirmation(result.data, goalId, workspace)
}
export async function submitGoalConfirmation(binding: GoalConfirmationBinding): Promise<GoalConfirmationEvidence> {
  const workspace = { basePath: binding.expected_workspace.base_path, mascRoot: binding.expected_workspace.masc_root }
  const { criterion: _criterion, observedProof: _observedProof, observedAuthorityKind: _observedAuthorityKind, ...request } = binding
  return decodeConfirmation(await post<unknown>('/api/v1/goals/confirmation', request, undefined, undefined, undefined, true), binding.goal_id, workspace)
}

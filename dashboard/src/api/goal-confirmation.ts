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
  runtimeInstanceId: string
  authorityKind: 'system_llm_agent' | 'human_operator'
}
export interface GoalConfirmationBinding {
  goal_id: string
  criterion_revision: string
  request_id: string
  verification_run_id: string
  expected_workspace: { base_path: string; masc_root: string }
  expected_operator_id: string
  expected_runtime_instance_id: string
  criterion: GoalProofCriterion
  observedProof: Proven
  observedAuthorityKind: 'system_llm_agent' | 'human_operator'
}

export function decodeConfirmation(raw: unknown, goalId: string, workspace: ArtifactWorkspace, runtimeInstanceId: string): GoalConfirmationEvidence {
  if (!isRecord(raw) || typeof raw.inspection_operator_id !== 'string' || raw.inspection_operator_id.trim() === '')
    throw new Error('증거를 조회한 운영자를 확인할 수 없습니다')
  if (!isRecord(raw) || !isRecord(raw.goal) || raw.goal.id !== goalId || typeof raw.goal.phase !== 'string')
    throw new Error('목표 확인 응답의 식별자가 일치하지 않습니다')
  if (!isRecord(raw.verification) || raw.verification.goal_id !== goalId)
    throw new Error('verifier 증거의 목표 식별자가 일치하지 않습니다')
  const decoded = decodeGoalProof(raw.verification, goalId)
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
  return { goalId, phase: raw.goal.phase, proof: decoded.completion, workspace, inspectionOperatorId: raw.inspection_operator_id, runtimeInstanceId,
    authorityKind: authority.kind }
}

export function confirmationBinding(evidence: GoalConfirmationEvidence): GoalConfirmationBinding {
  return { goal_id: evidence.goalId, criterion_revision: evidence.proof.criterion.revision,
    request_id: evidence.proof.requestId, verification_run_id: evidence.proof.runId,
    expected_workspace: artifactWorkspaceBody(evidence.workspace), expected_operator_id: evidence.inspectionOperatorId,
    expected_runtime_instance_id: evidence.runtimeInstanceId,
    criterion: evidence.proof.criterion, observedProof: evidence.proof, observedAuthorityKind: evidence.authorityKind }
}
export function sameConfirmationBinding(evidence: GoalConfirmationEvidence, binding: GoalConfirmationBinding): boolean {
  const current = confirmationBinding(evidence)
  return current.goal_id === binding.goal_id && current.criterion_revision === binding.criterion_revision
    && current.request_id === binding.request_id && current.verification_run_id === binding.verification_run_id
    && current.expected_workspace.base_path === binding.expected_workspace.base_path
    && current.expected_workspace.masc_root === binding.expected_workspace.masc_root
    && current.expected_operator_id === binding.expected_operator_id
    && current.expected_runtime_instance_id === binding.expected_runtime_instance_id
    && current.criterion.revision === binding.criterion.revision && current.criterion.title === binding.criterion.title
    && current.criterion.metric === binding.criterion.metric && current.criterion.target_value === binding.criterion.target_value
    && current.observedProof.evidence === binding.observedProof.evidence
    && current.observedProof.actor === binding.observedProof.actor
    && current.observedProof.recordedAt === binding.observedProof.recordedAt
    && current.observedAuthorityKind === binding.observedAuthorityKind
}
export async function readGoalConfirmation(goalId: string, workspace: ArtifactWorkspace, executionEpoch: string,
  onAuthorityRefused?: (status?: number) => void): Promise<GoalConfirmationEvidence> {
  const query = artifactWorkspaceQuery(workspace)
  query.set('goal_id', goalId)
  const instanceFrom = (headers: Headers) => {
    requireArtifactWorkspaceRead(headers)
    if (headers.get('x-masc-execution-publication-epoch') !== executionEpoch)
      throw new Error('서버 실행 세대가 변경되어 증거를 다시 조회해야 합니다')
    const instance = headers.get('x-masc-runtime-instance-id')
    if (!instance || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(instance))
      throw new Error('증거를 제공한 서버 인스턴스를 확인할 수 없습니다')
    return instance
  }
  const result = await getWithResponse<unknown>(`/api/v1/goals/confirmation?${query}`, {
    consumeWithinTimeout: true,
    preserveErrorBodyFailure: true,
    reportCredentialRefusal: false,
    beforeResponseBody: response => {
      if (!response.ok) { onAuthorityRefused?.(response.status); return }
      try { instanceFrom(response.headers) } catch (error) { onAuthorityRefused?.(); throw error }
    },
  })
  let instance: string
  try { instance = instanceFrom(result.headers) } catch (error) { onAuthorityRefused?.(); throw error }
  return decodeConfirmation(result.data, goalId, workspace, instance)
}
export async function submitGoalConfirmation(binding: GoalConfirmationBinding, onAuthorityRefused?: (status?: number) => void): Promise<GoalConfirmationEvidence> {
  const workspace = { basePath: binding.expected_workspace.base_path, mascRoot: binding.expected_workspace.masc_root }
  const { criterion: _criterion, observedProof: _observedProof, observedAuthorityKind: _observedAuthorityKind, ...request } = binding
  return decodeConfirmation(await post<unknown>('/api/v1/goals/confirmation', request, undefined, undefined, undefined, true,
    { reportCredentialRefusal: false, preserveErrorBodyFailure: true,
      beforeResponseBody: response => { if (!response.ok) onAuthorityRefused?.(response.status) } }),
    binding.goal_id, workspace, binding.expected_runtime_instance_id)
}

import { isRecord } from '../components/common/normalize'
import type { GoalProof, GoalProofCompletion, GoalProofCriterion } from '../types/core'

function nonblank(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}

function criterion(raw: unknown): GoalProofCriterion | null {
  if (!isRecord(raw) || !nonblank(raw.revision) || typeof raw.title !== 'string'
    || !(raw.metric === null || typeof raw.metric === 'string')
    || !(raw.target_value === null || typeof raw.target_value === 'string')) return null
  return { revision: raw.revision, title: raw.title, metric: raw.metric, target_value: raw.target_value }
}

function completion(raw: unknown): GoalProofCompletion | null {
  if (!isRecord(raw)) return null
  switch (raw.state) {
    case 'idle': return { state: 'idle' }
    case 'proof_pending': {
      const bound = criterion(raw.criterion)
      return bound && nonblank(raw.request_id) && nonblank(raw.requested_at)
        ? { state: 'pending', criterion: bound, requestId: raw.request_id, requestedAt: raw.requested_at }
        : null
    }
    case 'proof_proven':
    case 'proof_refuted': {
      const verdict = raw.verdict
      if (!isRecord(verdict)) return null
      const bound = criterion(verdict.criterion)
      const authority = verdict.authority
      if (!bound || !nonblank(verdict.request_id) || !nonblank(verdict.verification_run_id)
        || !nonblank(verdict.evidence) || !nonblank(verdict.recorded_at)
        || !isRecord(authority) || !nonblank(authority.actor)
        || !(authority.kind === 'system_llm_agent' || authority.kind === 'human_operator')) return null
      const proof = { criterion: bound, requestId: verdict.request_id, runId: verdict.verification_run_id,
        evidence: verdict.evidence, recordedAt: verdict.recorded_at, actor: authority.actor }
      if (raw.state === 'proof_proven' && verdict.outcome === 'proven' && verdict.reason === null)
        return { ...proof, state: 'proven' }
      if (raw.state === 'proof_refuted' && verdict.outcome === 'refuted' && nonblank(verdict.reason))
        return { ...proof, state: 'refuted', reason: verdict.reason }
      return null
    }
    default: return null
  }
}

export function decodeGoalProof(raw: unknown): GoalProof {
  if (!isRecord(raw)) return { state: 'unreadable', detail: '검증 원장이 응답에 없습니다' }
  if (raw.state === 'ledger_error' && nonblank(raw.detail))
    return { state: 'unreadable', detail: raw.detail }
  if (!nonblank(raw.goal_id) || !nonblank(raw.updated_at) || !isRecord(raw.completion))
    return { state: 'unreadable', detail: '검증 원장의 필드가 올바르지 않습니다' }
  if (raw.completion.state === 'stale_criterion') {
    const historical = completion(raw.completion.historical_completion)
    if (historical && historical.state !== 'idle') return { state: 'stale', historical }
  } else {
    const current = completion(raw.completion)
    if (current) return { state: 'current', completion: current }
  }
  return { state: 'unreadable', detail: '검증 상태 또는 판정 증거를 해석할 수 없습니다' }
}

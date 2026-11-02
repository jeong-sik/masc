import { isRecord } from '../components/common/normalize'
import { ApiRequestError, getWithResponse } from './core'
import { artifactWorkspaceQuery, requireArtifactWorkspaceRead, type ArtifactWorkspace } from './published-artifacts'

type Identity = { request_id: string; verification_run_id: string }
type Snapshot = 'matching' | 'missing' | 'conflicting'
type Allocation = { keeper: string; weight: string; amount_milli: string }
export type GoalCandleIssue =
  | { kind: 'same_second'; task_id: string; boundary: 'goal_created' | 'human_confirmed'; completed_at: string }
  | { kind: 'task_missing' | 'task_unobserved' | 'unfenced_nonterminal'; task_id: string }
  | { kind: 'reversed_window'; goal_created_at: string; confirmed_at: string }
type IssueObservation = { state: 'complete' | 'snapshot_independent'; entries: GoalCandleIssue[] } | { state: 'unavailable' }
export type GoalCandlePayout =
  | { state: 'no_recorded_obligation' | 'inconsistent' }
  | (Identity & { state: 'owed'; snapshot: Snapshot; stage: 'candidates_unrecorded' | 'candidates_consistent' | 'candidates_inconsistent' | 'candidates_unchecked' })
  | (Identity & { state: 'held'; snapshot: Snapshot; origin: 'stored' | 'derived_candidates'; issues: IssueObservation })
  | (Identity & { state: 'paid'; recorded_at: string; allocations: Allocation[] })
  | (Identity & { state: 'unattributed'; recorded_at: string; reason: 'no_candidates' | 'all_unrelated' | 'no_related_keepers' })
  | (Identity & { state: 'payout_failed'; reason: 'recorded_unreadable_due_date' })
export type GoalCandleObservation = {
  config: 'enabled' | 'off' | 'disabled'
  ledger: { state: 'missing' } | { state: 'unavailable'; reason: 'locked' | 'unreadable' | 'invalid_row' }
    | { state: 'observed'; payout: GoalCandlePayout }
}

function requireValue(condition: unknown): asserts condition {
  if (!condition) throw new Error('유효하지 않은 Candle 지급 관측 응답')
}
function keys(value: Record<string, unknown>, expected: string[]) {
  requireValue(Object.keys(value).length === expected.length && expected.every(key => Object.hasOwn(value, key)))
}
function text(value: unknown): string {
  requireValue(typeof value === 'string' && value.trim() !== '')
  return value
}
function choice<T extends string>(value: unknown, values: readonly T[]): T {
  requireValue(typeof value === 'string' && values.includes(value as T))
  return value as T
}
function integerText(value: unknown): string {
  requireValue(typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value))
  return value
}
function issue(raw: unknown): GoalCandleIssue {
  requireValue(isRecord(raw))
  const kind = choice(raw.kind, ['same_second', 'task_missing', 'task_unobserved', 'unfenced_nonterminal', 'reversed_window'] as const)
  if (kind === 'same_second') {
    keys(raw, ['kind', 'task_id', 'boundary', 'completed_at'])
    return { kind, task_id: text(raw.task_id), boundary: choice(raw.boundary, ['goal_created', 'human_confirmed'] as const), completed_at: text(raw.completed_at) }
  }
  if (kind === 'reversed_window') {
    keys(raw, ['kind', 'goal_created_at', 'confirmed_at'])
    return { kind, goal_created_at: text(raw.goal_created_at), confirmed_at: text(raw.confirmed_at) }
  }
  keys(raw, ['kind', 'task_id'])
  return { kind, task_id: text(raw.task_id) }
}
function payout(raw: unknown): GoalCandlePayout {
  requireValue(isRecord(raw))
  const state = choice(raw.state, ['no_recorded_obligation', 'inconsistent', 'owed', 'held', 'paid', 'unattributed', 'payout_failed'] as const)
  if (state === 'no_recorded_obligation' || state === 'inconsistent') {
    keys(raw, ['state'])
    return { state }
  }
  const identity = { request_id: text(raw.request_id), verification_run_id: text(raw.verification_run_id) }
  const identityKeys = ['state', 'request_id', 'verification_run_id']
  if (state === 'owed') {
    keys(raw, [...identityKeys, 'snapshot', 'stage'])
    return { state, ...identity, snapshot: choice(raw.snapshot, ['matching', 'missing', 'conflicting'] as const),
      stage: choice(raw.stage, ['candidates_unrecorded', 'candidates_consistent', 'candidates_inconsistent', 'candidates_unchecked'] as const) }
  }
  if (state === 'held') {
    keys(raw, [...identityKeys, 'snapshot', 'origin', 'issues'])
    requireValue(isRecord(raw.issues))
    const issueState = choice(raw.issues.state, ['complete', 'snapshot_independent', 'unavailable'] as const)
    let issues: IssueObservation
    if (issueState === 'unavailable') { keys(raw.issues, ['state']); issues = { state: issueState } }
    else {
      keys(raw.issues, ['state', 'entries'])
      requireValue(Array.isArray(raw.issues.entries))
      issues = { state: issueState, entries: raw.issues.entries.map(issue) }
    }
    return { state, ...identity, snapshot: choice(raw.snapshot, ['matching', 'missing', 'conflicting'] as const),
      origin: choice(raw.origin, ['stored', 'derived_candidates'] as const), issues }
  }
  if (state === 'paid') {
    keys(raw, [...identityKeys, 'recorded_at', 'allocations'])
    requireValue(Array.isArray(raw.allocations))
    const names = new Set<string>()
    const allocations = raw.allocations.map((entry): Allocation => {
      requireValue(isRecord(entry))
      keys(entry, ['keeper', 'weight', 'amount_milli'])
      const keeper = text(entry.keeper)
      requireValue(!names.has(keeper))
      names.add(keeper)
      return { keeper, weight: integerText(entry.weight), amount_milli: integerText(entry.amount_milli) }
    })
    return { state, ...identity, recorded_at: text(raw.recorded_at), allocations }
  }
  if (state === 'unattributed') {
    keys(raw, [...identityKeys, 'recorded_at', 'reason'])
    return { state, ...identity, recorded_at: text(raw.recorded_at),
      reason: choice(raw.reason, ['no_candidates', 'all_unrelated', 'no_related_keepers'] as const) }
  }
  keys(raw, [...identityKeys, 'reason'])
  return { state, ...identity, reason: choice(raw.reason, ['recorded_unreadable_due_date'] as const) }
}

export function decodeGoalCandle(raw: unknown, goalId: string): GoalCandleObservation {
  requireValue(isRecord(raw))
  keys(raw, ['schema', 'goal_id', 'config', 'ledger', 'execution'])
  requireValue(raw.schema === 'masc.goal-candle-observation.v1' && raw.goal_id === goalId)
  requireValue(isRecord(raw.config) && isRecord(raw.ledger) && isRecord(raw.execution))
  keys(raw.config, ['state'])
  keys(raw.execution, ['state', 'reason'])
  requireValue(raw.execution.state === 'not_observed' && raw.execution.reason === 'no_complete_goal_request_index')
  const config = choice(raw.config.state, ['enabled', 'off', 'disabled'] as const)
  const state = choice(raw.ledger.state, ['missing', 'unavailable', 'observed'] as const)
  if (state === 'missing') { keys(raw.ledger, ['state']); return { config, ledger: { state } } }
  if (state === 'unavailable') {
    keys(raw.ledger, ['state', 'reason'])
    return { config, ledger: { state, reason: choice(raw.ledger.reason, ['locked', 'unreadable', 'invalid_row'] as const) } }
  }
  keys(raw.ledger, ['state', 'payout'])
  return { config, ledger: { state, payout: payout(raw.ledger.payout) } }
}

export class GoalCandleEpochMismatchError extends Error {
  constructor() { super('서버 실행 세대가 변경되어 지급 기록을 다시 확인해야 합니다') }
}
export class GoalCandleWorkspaceRefusalError extends Error {
  constructor() { super('작업 공간을 다시 확인해야 합니다') }
}

export async function readGoalCandle(goalId: string, workspace: ArtifactWorkspace, executionEpoch: string,
  onResponseRefused?: (error: ApiRequestError) => void): Promise<GoalCandleObservation> {
  const query = artifactWorkspaceQuery(workspace)
  query.set('goal_id', goalId)
  const path = `/api/v1/dashboard/goals/candle?${query}`
  const validateHeaders = (headers: Headers) => {
    requireArtifactWorkspaceRead(headers)
    const observedEpoch = headers.get('x-masc-execution-publication-epoch')
    if (!observedEpoch?.trim()) throw new Error('서버 실행 세대를 확인할 수 없습니다')
    if (observedEpoch !== executionEpoch) throw new GoalCandleEpochMismatchError()
  }
  const result = await getWithResponse<unknown>(path, { consumeWithinTimeout: true, preserveErrorBodyFailure: true,
    // This response is tied to one workspace and Goal. The shared recovery
    // listener knows only the bearer and could otherwise change credentials
    // after this request's workspace or owner has been retired.
    reportCredentialRefusal: false,
    beforeResponseBody: response => {
      if (response.status === 409) throw new GoalCandleWorkspaceRefusalError()
      if (!response.ok) {
        // Retain every HTTP refusal immediately, then read its body for the
        // server's detailed reason if it arrives.
        onResponseRefused?.(new ApiRequestError({ method: 'GET', path, status: response.status, statusText: response.statusText }))
        return
      }
      validateHeaders(response.headers)
    },
  })
  validateHeaders(result.headers)
  return decodeGoalCandle(result.data, goalId)
}

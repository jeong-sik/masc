// Standalone Goal-verifier run projection.
// Backend: lib/goal_verification_run_registry.ml
// Route: GET /api/v1/dashboard/goal-verification-runs

import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import { decodeGoalProofCriterion } from './goal-proof'
import type { GoalProofCriterion } from '../types/core'
import {
  parseVerificationToolObservation,
  type VerificationToolObservation,
} from './dashboard-verification-runs'

export type GoalVerificationReviewKind = 'proof'
export type GoalVerificationRunStatus = 'running' | 'reviewed' | 'committed' | 'deferred' | 'raised' | 'superseded' | 'review_cancelled'

// RFC-0444 §2.3 row 7: every row names its arm. A review is one Goal proof
// run; a skipped scan is a verifier pass the goal store refused, which
// reviewed nothing and carries the goal_store_unavailable envelope's members.
export type GoalVerificationRowKind = 'review' | 'scan_skipped'
export type GoalStoreUnavailableReason = 'missing_after_init' | 'unreadable' | 'not_json' | 'schema_rejected'
export type GoalStoreMirrorStatus = 'mirror_absent' | 'mirror_unreadable' | 'mirror_decodes' | 'mirror_rejected'
export type GoalStoreResetStep = 'repair_field' | 'reset_goal_store' | 'restore_permission'

export interface GoalVerificationScanSkippedRecord {
  runId: string
  startedAt: number
  reason: GoalStoreUnavailableReason
  field: string | null
  file: string
  mirror: { status: GoalStoreMirrorStatus; goalCount: number | null }
  resetStep: GoalStoreResetStep
}

export interface GoalVerificationRunRecord {
  runId: string
  goalId: string
  requestId: string
  criterion: GoalProofCriterion
  evaluatedVerdict?: { decision: 'approved' | 'rejected'; reason: string } | null
  reviewKind: GoalVerificationReviewKind
  authorityActor: string
  startedAt: number
  status: GoalVerificationRunStatus
  elapsedSeconds?: number
  evaluatorRuntime?: string
  detail?: string
  tools?: VerificationToolObservation[]
}

export interface DashboardGoalVerificationRunsResponse {
  runs: GoalVerificationRunRecord[]
  skippedScans: GoalVerificationScanSkippedRecord[]
  count: number
  generatedAt: string
}

function protocolError(message: string): never {
  throw new Error(`Invalid Goal verification runs response: ${message}`)
}

function exactFields(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[],
  context: string,
): void {
  const expected = new Set([...required, ...optional])
  const missing = required.filter(field => !(field in value))
  const unknown = Object.keys(value).filter(field => !expected.has(field))
  if (missing.length > 0 || unknown.length > 0) {
    protocolError(`${context} fields mismatch (missing=[${missing.join(',')}], unknown=[${unknown.join(',')}])`)
  }
}

function nonEmptyString(value: unknown, context: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    protocolError(`${context} must be a non-empty string`)
  }
  return value
}

function finiteNonNegative(value: unknown, context: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    protocolError(`${context} must be a finite non-negative number`)
  }
  return value
}

function parseScanSkipped(raw: Record<string, unknown>, context: string): GoalVerificationScanSkippedRecord {
  exactFields(raw, ['kind', 'run_id', 'started_at', 'reason', 'field', 'file', 'mirror', 'reset_step'], [], context)
  const reason = raw.reason
  if (reason !== 'missing_after_init' && reason !== 'unreadable' && reason !== 'not_json' && reason !== 'schema_rejected') {
    protocolError(`${context}.reason has unknown value ${JSON.stringify(reason)}`)
  }
  const field = raw.field
  if (field !== null && typeof field !== 'string') protocolError(`${context}.field must be a string or null`)
  if (!isRecord(raw.mirror)) protocolError(`${context}.mirror must be an object`)
  exactFields(raw.mirror, ['status', 'goal_count'], [], `${context}.mirror`)
  const mirrorStatus = raw.mirror.status
  if (mirrorStatus !== 'mirror_absent' && mirrorStatus !== 'mirror_unreadable' && mirrorStatus !== 'mirror_decodes' && mirrorStatus !== 'mirror_rejected') {
    protocolError(`${context}.mirror.status has unknown value ${JSON.stringify(mirrorStatus)}`)
  }
  const goalCount = raw.mirror.goal_count
  if (goalCount !== null && !Number.isSafeInteger(goalCount)) protocolError(`${context}.mirror.goal_count must be an integer or null`)
  const resetStep = raw.reset_step
  if (resetStep !== 'repair_field' && resetStep !== 'reset_goal_store' && resetStep !== 'restore_permission') {
    protocolError(`${context}.reset_step has unknown value ${JSON.stringify(resetStep)}`)
  }
  return {
    runId: nonEmptyString(raw.run_id, `${context}.run_id`),
    startedAt: finiteNonNegative(raw.started_at, `${context}.started_at`),
    reason,
    field,
    file: nonEmptyString(raw.file, `${context}.file`),
    mirror: { status: mirrorStatus, goalCount: goalCount as number | null },
    resetStep,
  }
}

function parseRun(raw: Record<string, unknown>, context: string): GoalVerificationRunRecord {
  const status = raw.status
  if (status !== 'running' && status !== 'reviewed' && status !== 'committed' && status !== 'deferred' && status !== 'raised' && status !== 'superseded' && status !== 'review_cancelled') {
    protocolError(`${context}.status has unknown value ${JSON.stringify(status)}`)
  }
  const reviewKind = raw.review_kind
  if (reviewKind !== 'proof') {
    protocolError(`${context}.review_kind has unknown value ${JSON.stringify(reviewKind)}`)
  }
  const baseFields = [
    'kind',
    'run_id',
    'goal_id',
    'request_id',
    'criterion',
    'review_kind',
    'authority_actor',
    'started_at',
    'status',
  ] as const
  const outcomeFields = status === 'running'
    ? []
    : status === 'reviewed' || status === 'committed'
      ? ['elapsed_s', 'tools', 'evaluated_verdict']
      : ['elapsed_s', 'tools', 'evaluated_verdict', 'detail']
  exactFields(raw, [...baseFields, ...outcomeFields], status === 'running' ? [] : ['evaluator_runtime'], context)
  if (!isRecord(raw.criterion)) protocolError(`${context}.criterion must be an object`)
  exactFields(raw.criterion, ['revision', 'title', 'metric', 'target_value'], [], `${context}.criterion`)
  const criterion = decodeGoalProofCriterion(raw.criterion)
  if (!criterion) protocolError(`${context}.criterion is invalid`)
  let evaluatedVerdict: GoalVerificationRunRecord['evaluatedVerdict']
  if (status !== 'running') {
    const value = raw.evaluated_verdict
    if (value === null) {
      if (status === 'reviewed' || status === 'committed') protocolError(`${context} requires an evaluated verdict`)
      evaluatedVerdict = null
    } else {
      if (!isRecord(value)) protocolError(`${context}.evaluated_verdict must be an object or null`)
      exactFields(value, ['decision', 'reason'], [], `${context}.evaluated_verdict`)
      if (value.decision !== 'approved' && value.decision !== 'rejected') protocolError(`${context}.evaluated_verdict.decision is unknown`)
      evaluatedVerdict = { decision: value.decision, reason: nonEmptyString(value.reason, `${context}.evaluated_verdict.reason`) }
    }
  }
  const tools = status === 'running'
    ? undefined
    : Array.isArray(raw.tools)
      ? raw.tools.map((tool, toolIndex) => parseVerificationToolObservation(tool, `${context}.tools[${toolIndex}]`))
      : protocolError(`${context}.tools must be an array`)
  return {
    runId: nonEmptyString(raw.run_id, `${context}.run_id`),
    goalId: nonEmptyString(raw.goal_id, `${context}.goal_id`),
    requestId: nonEmptyString(raw.request_id, `${context}.request_id`),
    criterion,
    evaluatedVerdict,
    reviewKind,
    authorityActor: nonEmptyString(raw.authority_actor, `${context}.authority_actor`),
    startedAt: finiteNonNegative(raw.started_at, `${context}.started_at`),
    status,
    elapsedSeconds: status === 'running'
      ? undefined
      : finiteNonNegative(raw.elapsed_s, `${context}.elapsed_s`),
    evaluatorRuntime: raw.evaluator_runtime === undefined
      ? undefined
      : nonEmptyString(raw.evaluator_runtime, `${context}.evaluator_runtime`),
    detail: status === 'deferred' || status === 'raised' || status === 'superseded' || status === 'review_cancelled'
      ? nonEmptyString(raw.detail, `${context}.detail`)
      : undefined,
    tools,
  }
}

export function parseGoalVerificationRunsResponse(
  raw: unknown,
): DashboardGoalVerificationRunsResponse {
  if (!isRecord(raw)) protocolError('root must be an object')
  exactFields(raw, ['runs', 'count', 'generated_at'], [], 'root')
  if (!Array.isArray(raw.runs)) protocolError('root.runs must be an array')
  if (!Number.isSafeInteger(raw.count) || (raw.count as number) < 0) {
    protocolError('root.count must be a non-negative safe integer')
  }
  const runs: GoalVerificationRunRecord[] = []
  const skippedScans: GoalVerificationScanSkippedRecord[] = []
  raw.runs.forEach((row, index) => {
    const context = `runs[${index}]`
    if (!isRecord(row)) protocolError(`${context} must be an object`)
    const kind = row.kind
    if (kind === 'review') {
      runs.push(parseRun(row, context))
    } else if (kind === 'scan_skipped') {
      skippedScans.push(parseScanSkipped(row, context))
    } else {
      protocolError(`${context}.kind has unknown value ${JSON.stringify(kind)}`)
    }
  })
  if (runs.length + skippedScans.length !== raw.count) {
    protocolError(`root.count=${String(raw.count)} does not match runs.length=${runs.length + skippedScans.length}`)
  }
  return {
    runs,
    skippedScans,
    count: raw.count as number,
    generatedAt: nonEmptyString(raw.generated_at, 'root.generated_at'),
  }
}

export async function fetchGoalVerificationRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardGoalVerificationRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/goal-verification-runs', { signal: opts?.signal })
  return parseGoalVerificationRunsResponse(raw)
}

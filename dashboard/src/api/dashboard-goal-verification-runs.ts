// Standalone Goal-verifier run projection.
// Backend: lib/goal_verification_run_registry.ml
// Route: GET /api/v1/dashboard/goal-verification-runs

import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import {
  parseVerificationToolObservation,
  type VerificationToolObservation,
} from './dashboard-verification-runs'

export type GoalVerificationReviewKind = 'proof'
export type GoalVerificationRunStatus = 'running' | 'reviewed' | 'committed' | 'deferred' | 'raised'

export interface GoalVerificationRunRecord {
  runId: string
  goalId: string
  reviewKind: GoalVerificationReviewKind
  authorityActor: string
  startedAt: number
  status: GoalVerificationRunStatus
  elapsedSeconds?: number
  evaluatorRuntime?: string
  retryable?: boolean
  detail?: string
  tools?: VerificationToolObservation[]
}

export interface DashboardGoalVerificationRunsResponse {
  runs: GoalVerificationRunRecord[]
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

function parseRun(raw: unknown, index: number): GoalVerificationRunRecord {
  const context = `runs[${index}]`
  if (!isRecord(raw)) protocolError(`${context} must be an object`)
  const status = raw.status
  if (status !== 'running' && status !== 'reviewed' && status !== 'committed' && status !== 'deferred' && status !== 'raised') {
    protocolError(`${context}.status has unknown value ${JSON.stringify(status)}`)
  }
  const reviewKind = raw.review_kind
  if (reviewKind !== 'proof') {
    protocolError(`${context}.review_kind has unknown value ${JSON.stringify(reviewKind)}`)
  }
  const baseFields = [
    'run_id',
    'goal_id',
    'review_kind',
    'authority_actor',
    'started_at',
    'status',
  ] as const
  const outcomeFields = status === 'running'
    ? []
    : status === 'reviewed' || status === 'committed'
      ? ['elapsed_s', 'tools']
      : status === 'deferred'
        ? ['elapsed_s', 'tools', 'retryable', 'detail']
        : ['elapsed_s', 'tools', 'detail']
  exactFields(raw, [...baseFields, ...outcomeFields], status === 'running' ? [] : ['evaluator_runtime'], context)
  const tools = status === 'running'
    ? undefined
    : Array.isArray(raw.tools)
      ? raw.tools.map((tool, toolIndex) => parseVerificationToolObservation(tool, `${context}.tools[${toolIndex}]`))
      : protocolError(`${context}.tools must be an array`)
  if (status === 'deferred' && typeof raw.retryable !== 'boolean') {
    protocolError(`${context}.retryable must be a boolean`)
  }
  return {
    runId: nonEmptyString(raw.run_id, `${context}.run_id`),
    goalId: nonEmptyString(raw.goal_id, `${context}.goal_id`),
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
    retryable: status === 'deferred' ? raw.retryable as boolean : undefined,
    detail: status === 'deferred' || status === 'raised'
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
  const runs = raw.runs.map(parseRun)
  if (runs.length !== raw.count) {
    protocolError(`root.count=${String(raw.count)} does not match runs.length=${runs.length}`)
  }
  return {
    runs,
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

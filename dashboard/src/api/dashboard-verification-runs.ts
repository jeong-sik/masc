// MASC Dashboard — completion-authority review registry fetcher + decoder.
//
// Backend: lib/verification_run_registry.ml (RFC-0361 D4)
// Route:   GET /api/v1/dashboard/verification-runs
//
// Sibling of dashboard-fusion.ts and deliberately shaped the same way. Distinct
// from the verification *requests* surface (dashboard-misc.ts): a request is
// what a Keeper submitted, a run is what the completion authority did with it.
// Only the registry shows a review that produced no verdict at all.

import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

/** How a completion-authority review ended, mirroring the closed backend
    Verification_run_registry.status_label vocabulary. */
export type VerificationRunStatusLabel =
  | 'running'
  | 'approved'
  | 'rejected'
  | 'infrastructure_unavailable'
  | 'not_reviewed'
  | 'commit_failed'
  | 'raised'
  | 'operator_routed'

export type VerificationToolDisposition = 'completed' | 'deferred' | 'failed'

export interface VerificationToolObservation {
  toolName: string
  input: unknown
  disposition: VerificationToolDisposition
  outputExcerpt: string
  outputTruncated: boolean
  durationMs: number
  finishedAt: number
}

const BACKEND_STATUSES: readonly string[] = [
  'running',
  'approved',
  'rejected',
  'infrastructure_unavailable',
  'not_reviewed',
  'commit_failed',
  'raised',
  'operator_routed',
]

/** One tracked review from the registry.

    `cause` is the operator-readable reason the outcome happened, flattened from
    the backend's per-outcome field (`reason` on an approval or a rejection,
    `detail` on the failure shapes). Absent on `running`, and on an approval
    whose reviewer stated nothing — rows written before approvals carried a
    reason have no such field at all. */
export interface VerificationRunRecord {
  verificationId: string
  taskId: string
  producer: string
  authorityKind: string
  authorityActor: string
  startedAt: number // unix seconds
  status: VerificationRunStatusLabel
  elapsedSeconds?: number
  evaluatorRuntime?: string
  cause?: string
  /** Which gate declined to produce a verdict; `not_reviewed` rows only. */
  gate?: string
  /** Whether the completion authority will schedule another automatic
      attempt for this outcome; `not_reviewed` rows only. `false` means the
      same review is expected to fail the same way — the task stays parked
      until an operator acts (resubmission, evidence trim, config change),
      not until the retry timer fires again. */
  retryable?: boolean
  /** Which pre-review boundary was unavailable. */
  infrastructureStage?: 'review_preparation' | 'lookup_surface'
  tools?: VerificationToolObservation[]
}

export interface DashboardVerificationRunsResponse {
  runs: VerificationRunRecord[]
  count: number
  generatedAt: string
}

function protocolError(message: string): never {
  throw new Error(`Invalid verification runs response: ${message}`)
}

function exactFields(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
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

function finiteNumber(value: unknown, context: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    protocolError(`${context} must be a finite number`)
  }
  return value
}

function optionalNonEmptyString(value: unknown, context: string): string | undefined {
  return value === undefined ? undefined : nonEmptyString(value, context)
}

function strictBoolean(value: unknown, context: string): boolean {
  if (typeof value !== 'boolean') {
    protocolError(`${context} must be a boolean`)
  }
  return value
}

function verificationStatus(value: unknown, context: string): VerificationRunStatusLabel {
  if (typeof value !== 'string' || !BACKEND_STATUSES.includes(value)) {
    protocolError(`${context} has unknown status ${JSON.stringify(value)}`)
  }
  return value as VerificationRunStatusLabel
}

export function parseVerificationToolObservation(
  raw: unknown,
  context: string,
): VerificationToolObservation {
  if (!isRecord(raw)) protocolError(`${context} must be an object`)
  exactFields(raw, [
    'tool_name',
    'input',
    'disposition',
    'output_excerpt',
    'output_truncated',
    'duration_ms',
    'finished_at',
  ], [], context)
  if (raw.disposition !== 'completed' && raw.disposition !== 'deferred' && raw.disposition !== 'failed') {
    protocolError(`${context}.disposition has unknown value ${JSON.stringify(raw.disposition)}`)
  }
  if (typeof raw.output_truncated !== 'boolean') {
    protocolError(`${context}.output_truncated must be a boolean`)
  }
  const durationMs = finiteNumber(raw.duration_ms, `${context}.duration_ms`)
  if (durationMs < 0) protocolError(`${context}.duration_ms must be non-negative`)
  const finishedAt = finiteNumber(raw.finished_at, `${context}.finished_at`)
  if (finishedAt < 0) protocolError(`${context}.finished_at must be non-negative`)
  return {
    toolName: nonEmptyString(raw.tool_name, `${context}.tool_name`),
    input: raw.input,
    disposition: raw.disposition,
    outputExcerpt: typeof raw.output_excerpt === 'string'
      ? raw.output_excerpt
      : protocolError(`${context}.output_excerpt must be a string`),
    outputTruncated: raw.output_truncated,
    durationMs,
    finishedAt,
  }
}

const RUN_BASE_FIELDS = [
  'verification_id',
  'task_id',
  'producer',
  'authority_kind',
  'authority_actor',
  'started_at',
  'status',
] as const

function parseRun(raw: unknown, index: number): VerificationRunRecord {
  const context = `runs[${index}]`
  if (!isRecord(raw)) protocolError(`${context} must be an object`)
  const status = verificationStatus(raw.status, `${context}.status`)
  let requiredOutcomeFields: readonly string[] = []
  let optionalFields: readonly string[] = []
  switch (status) {
    case 'running':
      break
    case 'approved':
      requiredOutcomeFields = ['elapsed_s', 'tools']
      // Optional, not required: rows written before an approval carried its
      // reviewer's stated reason have no `reason` field and must still decode.
      optionalFields = ['evaluator_runtime', 'reason']
      break
    case 'rejected':
      requiredOutcomeFields = ['elapsed_s', 'reason', 'tools']
      optionalFields = ['evaluator_runtime']
      break
    case 'not_reviewed':
      requiredOutcomeFields = ['elapsed_s', 'gate', 'detail', 'retryable', 'tools']
      optionalFields = ['evaluator_runtime']
      break
    case 'infrastructure_unavailable':
      requiredOutcomeFields = ['elapsed_s', 'stage', 'detail', 'tools']
      optionalFields = ['evaluator_runtime']
      break
    case 'commit_failed':
    case 'raised':
      requiredOutcomeFields = ['elapsed_s', 'detail', 'tools']
      optionalFields = ['evaluator_runtime']
      break
    case 'operator_routed':
      // The lane handed the claim to the operator without a review: no
      // evaluator, no gate, no cause beyond the status itself.
      requiredOutcomeFields = ['elapsed_s', 'tools']
      optionalFields = ['evaluator_runtime']
      break
  }
  exactFields(raw, [...RUN_BASE_FIELDS, ...requiredOutcomeFields], optionalFields, context)
  const startedAt = finiteNumber(raw.started_at, `${context}.started_at`)
  if (startedAt < 0) protocolError(`${context}.started_at must be non-negative`)
  const elapsedSeconds = status === 'running'
    ? undefined
    : finiteNumber(raw.elapsed_s, `${context}.elapsed_s`)
  if (elapsedSeconds != null && elapsedSeconds < 0) {
    protocolError(`${context}.elapsed_s must be non-negative`)
  }
  const tools = status === 'running'
    ? undefined
    : Array.isArray(raw.tools)
      ? raw.tools.map((tool, toolIndex) => parseVerificationToolObservation(tool, `${context}.tools[${toolIndex}]`))
      : protocolError(`${context}.tools must be an array`)
  return {
    verificationId: nonEmptyString(raw.verification_id, `${context}.verification_id`),
    taskId: nonEmptyString(raw.task_id, `${context}.task_id`),
    producer: nonEmptyString(raw.producer, `${context}.producer`),
    authorityKind: nonEmptyString(raw.authority_kind, `${context}.authority_kind`),
    authorityActor: nonEmptyString(raw.authority_actor, `${context}.authority_actor`),
    startedAt,
    status,
    elapsedSeconds,
    evaluatorRuntime: optionalNonEmptyString(raw.evaluator_runtime, `${context}.evaluator_runtime`),
    cause: status === 'rejected'
      ? nonEmptyString(raw.reason, `${context}.reason`)
      : status === 'approved'
      ? optionalNonEmptyString(raw.reason, `${context}.reason`)
      : status === 'infrastructure_unavailable' || status === 'not_reviewed'
        || status === 'commit_failed' || status === 'raised'
        ? nonEmptyString(raw.detail, `${context}.detail`)
        : undefined,
    gate: status === 'not_reviewed'
      ? nonEmptyString(raw.gate, `${context}.gate`)
      : undefined,
    retryable: status === 'not_reviewed'
      ? strictBoolean(raw.retryable, `${context}.retryable`)
      : undefined,
    infrastructureStage: status === 'infrastructure_unavailable'
      ? raw.stage === 'review_preparation' || raw.stage === 'lookup_surface'
        ? raw.stage
        : protocolError(`${context}.stage has unknown value ${JSON.stringify(raw.stage)}`)
      : undefined,
    tools,
  }
}

export function parseVerificationRunsResponse(raw: unknown): DashboardVerificationRunsResponse {
  if (!isRecord(raw)) protocolError('root must be an object')
  exactFields(raw, ['runs', 'count', 'generated_at'], [], 'root')
  if (!Array.isArray(raw.runs)) protocolError('root.runs must be an array')
  if (!Number.isSafeInteger(raw.count) || (raw.count as number) < 0) {
    protocolError('root.count must be a non-negative safe integer')
  }
  const runs = raw.runs.map(parseRun)
  if (raw.count !== runs.length) {
    protocolError(`root.count=${String(raw.count)} does not match runs.length=${runs.length}`)
  }
  return {
    runs,
    count: raw.count as number,
    generatedAt: nonEmptyString(raw.generated_at, 'root.generated_at'),
  }
}

export async function fetchVerificationRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardVerificationRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/verification-runs', { signal: opts?.signal })
  return parseVerificationRunsResponse(raw)
}

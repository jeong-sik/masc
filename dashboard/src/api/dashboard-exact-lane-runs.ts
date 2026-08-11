import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

export type ExactLane =
  | 'librarian_exact'
  | 'hitl_auto_judge'
  | 'board_attention_exact'
  | 'compaction_exact'

export type ExactLaneRunStatus =
  | 'running'
  | 'succeeded'
  | 'cancelled'
  | 'failed'
  | 'completion_persistence_failed'
  | 'completion_durability_unknown'

export type ExactLaneIntendedStatus = 'succeeded' | 'cancelled' | 'failed'
export type ExactLanePersistenceState = 'not_persisted' | 'durability_unknown'

export type ExactLaneRunInput = { kind: 'exact'; payload: unknown }

export interface ExactLaneRunRecord {
  runId: string
  lane: ExactLane
  subjectId: string
  actor: string
  startedAt: number
  input: ExactLaneRunInput
  status: ExactLaneRunStatus
  elapsedSeconds?: number
  output?: unknown
  code?: string
  detail?: string
  intendedStatus?: ExactLaneIntendedStatus
  intendedCode?: string
  intendedDetail?: string
  persistenceError?: string
  persistenceState?: ExactLanePersistenceState
}

export interface DashboardExactLaneRunsResponse {
  runs: ExactLaneRunRecord[]
  count: number
  generatedAt: string
}

const LANES: readonly string[] = [
  'librarian_exact',
  'hitl_auto_judge',
  'board_attention_exact',
  'compaction_exact',
]
const STATUSES: readonly string[] = [
  'running',
  'succeeded',
  'cancelled',
  'failed',
  'completion_persistence_failed',
  'completion_durability_unknown',
]
const INTENDED_STATUSES: readonly string[] = ['succeeded', 'cancelled', 'failed']

function fail(message: string): never {
  throw new Error(`Invalid exact lane runs response: ${message}`)
}

function string(value: unknown, context: string): string {
  if (typeof value !== 'string' || value.trim() === '') fail(`${context} must be a non-empty string`)
  return value
}

function number(value: unknown, context: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    fail(`${context} must be a non-negative finite number`)
  }
  return value
}

function exactFields(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[],
  context: string,
): void {
  const expected = new Set([...required, ...optional])
  const missing = required.filter(key => !(key in value))
  const unknown = Object.keys(value).filter(key => !expected.has(key))
  if (missing.length > 0 || unknown.length > 0) {
    fail(`${context} fields mismatch (missing=[${missing.join(',')}], unknown=[${unknown.join(',')}])`)
  }
}

function parseInput(raw: unknown, context: string): ExactLaneRunInput {
  if (!isRecord(raw)) fail(`${context} must be an object`)
  const kind = string(raw.kind, `${context}.kind`)
  if (kind === 'exact') {
    exactFields(raw, ['kind', 'payload'], [], context)
    return { kind, payload: raw.payload }
  }
  return fail(`${context}.kind has unknown value ${JSON.stringify(kind)}`)
}

function parseRun(raw: unknown, index: number): ExactLaneRunRecord {
  const context = `runs[${index}]`
  if (!isRecord(raw)) fail(`${context} must be an object`)
  const status = string(raw.status, `${context}.status`)
  if (!STATUSES.includes(status)) fail(`${context}.status has unknown value ${JSON.stringify(status)}`)
  const lane = string(raw.lane, `${context}.lane`)
  if (!LANES.includes(lane)) fail(`${context}.lane has unknown value ${JSON.stringify(lane)}`)
  const base = ['run_id', 'lane', 'subject_id', 'actor', 'started_at', 'input', 'status']
  const persistenceFailure = status === 'completion_persistence_failed'
    || status === 'completion_durability_unknown'
  const intendedStatus = persistenceFailure
    ? string(raw.intended_status, `${context}.intended_status`)
    : undefined
  if (intendedStatus !== undefined && !INTENDED_STATUSES.includes(intendedStatus)) {
    fail(`${context}.intended_status has unknown value ${JSON.stringify(intendedStatus)}`)
  }
  const intendedFailure = intendedStatus === 'failed'
  const required = status === 'running'
    ? base
    : persistenceFailure
      ? [
          ...base,
          'intended_status',
          'elapsed_s',
          'output',
          'persistence_error',
          'persistence_state',
          ...(intendedFailure ? ['intended_code', 'intended_detail'] : []),
        ]
      : status === 'failed'
        ? [...base, 'elapsed_s', 'output', 'code', 'detail']
        : [...base, 'elapsed_s', 'output']
  exactFields(raw, required, [], context)
  const persistenceState = persistenceFailure
    ? string(raw.persistence_state, `${context}.persistence_state`)
    : undefined
  const expectedPersistenceState = status === 'completion_persistence_failed'
    ? 'not_persisted'
    : status === 'completion_durability_unknown'
      ? 'durability_unknown'
      : undefined
  if (persistenceState !== expectedPersistenceState) {
    fail(`${context}.persistence_state must be ${JSON.stringify(expectedPersistenceState)}`)
  }
  return {
    runId: string(raw.run_id, `${context}.run_id`),
    lane: lane as ExactLane,
    subjectId: string(raw.subject_id, `${context}.subject_id`),
    actor: string(raw.actor, `${context}.actor`),
    startedAt: number(raw.started_at, `${context}.started_at`),
    input: parseInput(raw.input, `${context}.input`),
    status: status as ExactLaneRunStatus,
    elapsedSeconds: status === 'running' ? undefined : number(raw.elapsed_s, `${context}.elapsed_s`),
    output: status === 'running' ? undefined : raw.output,
    code: status === 'failed' ? string(raw.code, `${context}.code`) : undefined,
    detail: status === 'failed' ? string(raw.detail, `${context}.detail`) : undefined,
    intendedStatus: intendedStatus as ExactLaneIntendedStatus | undefined,
    intendedCode: intendedFailure ? string(raw.intended_code, `${context}.intended_code`) : undefined,
    intendedDetail: intendedFailure ? string(raw.intended_detail, `${context}.intended_detail`) : undefined,
    persistenceError: persistenceFailure
      ? string(raw.persistence_error, `${context}.persistence_error`)
      : undefined,
    persistenceState: persistenceState as ExactLanePersistenceState | undefined,
  }
}

export function parseExactLaneRunsResponse(raw: unknown): DashboardExactLaneRunsResponse {
  if (!isRecord(raw)) fail('root must be an object')
  exactFields(raw, ['runs', 'count', 'generated_at'], [], 'root')
  if (!Array.isArray(raw.runs)) fail('root.runs must be an array')
  if (!Number.isSafeInteger(raw.count) || (raw.count as number) < 0) {
    fail('root.count must be a non-negative safe integer')
  }
  const runs = raw.runs.map(parseRun)
  if (raw.count !== runs.length) fail('root.count must match runs.length')
  return {
    runs,
    count: raw.count as number,
    generatedAt: string(raw.generated_at, 'root.generated_at'),
  }
}

export async function fetchExactLaneRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardExactLaneRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/exact-lane-runs', { signal: opts?.signal })
  return parseExactLaneRunsResponse(raw)
}

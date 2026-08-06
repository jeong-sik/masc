import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

export type ExactLane =
  | 'librarian_exact'
  | 'hitl_auto_judge'
  | 'board_attention_exact'
  | 'compaction_exact'

export type ExactLaneRunStatus = 'running' | 'succeeded' | 'cancelled' | 'failed'

export interface ExactLaneRunRecord {
  runId: string
  lane: ExactLane
  subjectId: string
  actor: string
  startedAt: number
  input: unknown
  status: ExactLaneRunStatus
  elapsedSeconds?: number
  output?: unknown
  code?: string
  detail?: string
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
const STATUSES: readonly string[] = ['running', 'succeeded', 'cancelled', 'failed']

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

function parseRun(raw: unknown, index: number): ExactLaneRunRecord {
  const context = `runs[${index}]`
  if (!isRecord(raw)) fail(`${context} must be an object`)
  const status = string(raw.status, `${context}.status`)
  if (!STATUSES.includes(status)) fail(`${context}.status has unknown value ${JSON.stringify(status)}`)
  const lane = string(raw.lane, `${context}.lane`)
  if (!LANES.includes(lane)) fail(`${context}.lane has unknown value ${JSON.stringify(lane)}`)
  const base = ['run_id', 'lane', 'subject_id', 'actor', 'started_at', 'input', 'status']
  const required = status === 'running'
    ? base
    : status === 'failed'
      ? [...base, 'elapsed_s', 'output', 'code', 'detail']
      : [...base, 'elapsed_s', 'output']
  exactFields(raw, required, [], context)
  return {
    runId: string(raw.run_id, `${context}.run_id`),
    lane: lane as ExactLane,
    subjectId: string(raw.subject_id, `${context}.subject_id`),
    actor: string(raw.actor, `${context}.actor`),
    startedAt: number(raw.started_at, `${context}.started_at`),
    input: raw.input,
    status: status as ExactLaneRunStatus,
    elapsedSeconds: status === 'running' ? undefined : number(raw.elapsed_s, `${context}.elapsed_s`),
    output: status === 'running' ? undefined : raw.output,
    code: status === 'failed' ? string(raw.code, `${context}.code`) : undefined,
    detail: status === 'failed' ? string(raw.detail, `${context}.detail`) : undefined,
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

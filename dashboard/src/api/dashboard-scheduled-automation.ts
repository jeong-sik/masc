// Scheduled-automation projection client.
//
// Talks to GET /api/v1/dashboard/scheduled-automation, whose sole producer is
// Server_dashboard_schedule_projection. The projection used to arrive as a
// nested field of /api/v1/dashboard/tools, so any surface needing schedule
// state pulled the whole tool inventory with it.

import { get, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationFsm,
  DashboardScheduledAutomationRequest,
  DashboardScheduledAutomationWakeCounts,
} from './dashboard-tools-prompts'

const SCHEDULE_LOOKUP_SCHEMA = 'masc.dashboard.scheduled_automation.lookup.v1'

export type DashboardScheduledAutomationLookup =
  | { status: 'found'; scheduleId: string; request: DashboardScheduledAutomationRequest }
  | { status: 'not_found'; scheduleId: string }
  | { status: 'unavailable'; scheduleId: string; reason: string }
  | { status: 'invalid_id'; scheduleId: string; reason: string }

export interface DashboardScheduledAutomationPage {
  /** Rows materialized in this response. */
  visibleCount: number
  /** Total rows in the schedule ledger. */
  totalCount: number
  /** Maximum rows this projection may materialize. */
  limit: number
  /** Whether the server omitted rows beyond [limit]. */
  truncated: boolean
}

export type DashboardScheduledAutomationAvailableData =
  Omit<
    DashboardScheduledAutomation,
    | 'status'
    | 'schedule_store_known'
    | 'schedule_store_read_error'
    | 'request_count'
    | 'request_limit'
    | 'counts'
    | 'fsm'
  > & {
    status: 'ok'
    schedule_store_known: true
    schedule_store_read_error: null
    request_count: number
    request_limit: number
    counts: Record<string, number>
    fsm: DashboardScheduledAutomationFsm & {
      active_count: number
      terminal_count: number
    }
  }

/** A ledger-backed projection is either completely countable or unavailable.
 *
 * Keeping the failure as a discriminant prevents downstream components from
 * turning the server's null counts and empty placeholder row list into a
 * healthy-looking zero. */
export type DashboardScheduledAutomationProjection =
  | {
    state: 'available'
    data: DashboardScheduledAutomationAvailableData
    page: DashboardScheduledAutomationPage
  }
  | {
    state: 'unavailable'
    reason: string
  }

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function exactFields(
  record: Record<string, unknown>,
  required: readonly string[],
  context: string,
): void {
  const expected = new Set(required)
  const missing = required.filter(field => !(field in record))
  const unknown = Object.keys(record).filter(field => !expected.has(field))
  if (missing.length > 0 || unknown.length > 0) {
    throw new Error(
      `${context} fields mismatch (missing=[${missing.join(',')}], unknown=[${unknown.join(',')}])`,
    )
  }
}

function parseLookupRequest(
  value: unknown,
  expectedScheduleId: string,
): DashboardScheduledAutomationRequest {
  const request = asRecord(value)
  if (!request || request.schedule_id !== expectedScheduleId) {
    throw new Error('Invalid scheduled-automation lookup response: request identity mismatch')
  }
  switch (request.status) {
    case 'scheduled':
    case 'due':
    case 'running':
    case 'succeeded':
    case 'failed':
    case 'cancelled':
    case 'expired':
      break
    default:
      throw new Error('Invalid scheduled-automation lookup response: invalid request status')
  }
  if (typeof request.source !== 'string' || request.source.trim() === '') {
    throw new Error('Invalid scheduled-automation lookup response: invalid request source')
  }
  return request as unknown as DashboardScheduledAutomationRequest
}

export function decodeScheduledAutomationLookup(
  raw: unknown,
  expectedScheduleId: string,
): DashboardScheduledAutomationLookup {
  const record = asRecord(raw)
  if (!record) throw new Error('Invalid scheduled-automation lookup response: envelope must be an object')
  if (record.schema !== SCHEDULE_LOOKUP_SCHEMA || record.source !== 'schedule_store') {
    throw new Error('Invalid scheduled-automation lookup response: unsupported schema or source')
  }
  if (
    typeof record.generated_at !== 'string'
    || record.generated_at.trim() === ''
    || typeof record.schedule_id !== 'string'
  ) {
    throw new Error('Invalid scheduled-automation lookup response: invalid generated_at or schedule_id')
  }
  const scheduleId = record.schedule_id
  if (scheduleId !== expectedScheduleId) {
    throw new Error('Invalid scheduled-automation lookup response: envelope identity mismatch')
  }
  switch (record.status) {
    case 'found':
      exactFields(record, ['schema', 'source', 'generated_at', 'status', 'schedule_id', 'request'], 'envelope')
      return { status: 'found', scheduleId, request: parseLookupRequest(record.request, scheduleId) }
    case 'not_found':
      exactFields(record, ['schema', 'source', 'generated_at', 'status', 'schedule_id'], 'envelope')
      return { status: 'not_found', scheduleId }
    case 'unavailable':
      exactFields(record, ['schema', 'source', 'generated_at', 'status', 'schedule_id', 'reason'], 'envelope')
      if (typeof record.reason !== 'string' || record.reason.trim() === '') {
        throw new Error('Invalid scheduled-automation lookup response: invalid reason')
      }
      return { status: 'unavailable', scheduleId, reason: record.reason }
    case 'invalid_id':
      exactFields(record, ['schema', 'source', 'generated_at', 'status', 'schedule_id', 'reason'], 'envelope')
      if (typeof record.reason !== 'string' || record.reason.trim() === '') {
        throw new Error('Invalid scheduled-automation lookup response: invalid reason')
      }
      return { status: 'invalid_id', scheduleId, reason: record.reason }
    default:
      throw new Error(`Invalid scheduled-automation lookup response: unknown status ${JSON.stringify(record.status)}`)
  }
}

/** A count the server reported, or null when it reported none.
 *
 *  The server sends null for every count when the schedule ledger could not be
 *  read (`status: "unknown"` plus `schedule_store_read_error`). Coercing that
 *  to 0 would render an unreadable ledger as "no schedules", which is the one
 *  substitution this projection must never make. */
function countOrNull(value: unknown): number | null {
  return typeof value === 'number'
    && Number.isFinite(value)
    && Number.isInteger(value)
    && value >= 0
    ? value
    : null
}

function normalizeFsm(raw: unknown): DashboardScheduledAutomationFsm {
  const record = asRecord(raw)
  if (!record) {
    return { state: 'unknown', active_count: null, terminal_count: null, next_due_at: null }
  }
  const state =
    typeof record.state === 'string' && record.state.trim() !== '' ? record.state : 'unknown'
  return {
    state,
    active_count: countOrNull(record.active_count),
    terminal_count: countOrNull(record.terminal_count),
    next_due_at: typeof record.next_due_at === 'string' ? record.next_due_at : null,
  }
}

function normalizeCounts(raw: unknown): Record<string, number> | null {
  const record = asRecord(raw)
  if (!record) return null
  const counts: Record<string, number> = {}
  for (const [key, value] of Object.entries(record)) {
    const count = countOrNull(value)
    if (count !== null) counts[key] = count
  }
  return counts
}

const WAKE_COUNT_KEYS = [
  'retained',
  'running',
  'succeeded',
  'failed',
  'active_with_failed_newest_wake',
  'retention_per_schedule',
] as const

// Every key or nothing: a partial object would render a real zero next to a
// missing number, and the strip cannot tell those apart once they are ints.
function normalizeWakeCounts(raw: unknown): DashboardScheduledAutomationWakeCounts | null {
  const record = asRecord(raw)
  if (!record) return null
  const counts: Partial<Record<(typeof WAKE_COUNT_KEYS)[number], number>> = {}
  for (const key of WAKE_COUNT_KEYS) {
    const value = record[key]
    if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) return null
    counts[key] = value
  }
  return counts as DashboardScheduledAutomationWakeCounts
}

function normalizeScheduledAutomationPayload(raw: unknown): DashboardScheduledAutomation {
  const record = asRecord(raw) ?? {}
  const requests = Array.isArray(record.requests) ? record.requests : []
  const signals = Array.isArray(record.signals) ? record.signals : []
  const warnings = Array.isArray(record.warnings)
    ? record.warnings.filter((warning): warning is string => typeof warning === 'string')
    : []
  return {
    ...(record as Partial<DashboardScheduledAutomation>),
    // request_count stays null on a read error rather than falling back to
    // `requests.length`: an empty row list under an unreadable ledger means
    // "we have no rows to show", not "there are zero schedules".
    request_count: countOrNull(record.request_count),
    request_limit: countOrNull(record.request_limit),
    truncated: record.truncated === true,
    counts: normalizeCounts(record.counts),
    wake_counts: normalizeWakeCounts(record.wake_counts),
    signals,
    requests,
    warnings,
    fsm: normalizeFsm(record.fsm),
  } as DashboardScheduledAutomation
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

export function normalizeScheduledAutomation(
  raw: unknown,
): DashboardScheduledAutomationProjection {
  const record = asRecord(raw) ?? {}
  const data = normalizeScheduledAutomationPayload(record)
  const status = nonEmptyString(record.status)
  const readError = nonEmptyString(record.schedule_store_read_error)

  if (readError) {
    return { state: 'unavailable', reason: readError }
  }
  if (record.schedule_store_known === false || status === 'unknown') {
    return {
      state: 'unavailable',
      reason: 'schedule ledger status is unknown',
    }
  }

  const requestCount = data.request_count
  const requestLimit = data.request_limit
  const counts = data.counts
  const activeCount = data.fsm.active_count
  const terminalCount = data.fsm.terminal_count
  if (
    status !== 'ok'
    || record.schedule_store_known !== true
    || record.schedule_store_read_error !== null
    || requestCount === null
    || requestLimit === null
    || counts === null
    || activeCount === null
    || terminalCount === null
    || typeof record.truncated !== 'boolean'
  ) {
    return {
      state: 'unavailable',
      reason: 'schedule ledger projection is incomplete',
    }
  }

  const availableData: DashboardScheduledAutomationAvailableData = {
    ...data,
    status: 'ok',
    schedule_store_known: true,
    schedule_store_read_error: null,
    request_count: requestCount,
    request_limit: requestLimit,
    counts,
    fsm: {
      ...data.fsm,
      active_count: activeCount,
      terminal_count: terminalCount,
    },
  }
  return {
    state: 'available',
    data: availableData,
    page: {
      visibleCount: data.requests.length,
      totalCount: requestCount,
      limit: requestLimit,
      truncated: data.truncated,
    },
  }
}

export async function fetchDashboardScheduledAutomation(
  opts?: AbortableRequestOptions,
): Promise<DashboardScheduledAutomationProjection> {
  await ensureDevToken()
  const raw = await get<unknown>('/api/v1/dashboard/scheduled-automation', {
    signal: opts?.signal,
  })
  return normalizeScheduledAutomation(raw)
}

export async function fetchDashboardScheduledAutomationLookup(
  scheduleId: string,
  opts?: AbortableRequestOptions,
): Promise<DashboardScheduledAutomationLookup> {
  await ensureDevToken()
  const query = new URLSearchParams({ schedule_id: scheduleId })
  const raw = await get<unknown>(`/api/v1/dashboard/scheduled-automation?${query}`, {
    signal: opts?.signal,
  })
  return decodeScheduledAutomationLookup(raw, scheduleId)
}

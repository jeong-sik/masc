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
} from './dashboard-tools-prompts'

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

// MASC Dashboard — Misc projections: memory subsystems /
// keeper memory health / verification requests / TLA specs+TLC results / audit.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { asNumber, isRecord } from '../components/common/normalize'

// --- Keeper Memory Health ---

export type KeeperMemoryHealthAlertCode =
  | 'snapshot_read_error'
  | 'source_snapshot_read_error'
  | 'librarian_failures'
  | 'librarian_starvation'
  | 'vision_ingest_errors'

export type KeeperMemoryHealthAlertSeverity = 'warn' | 'error'

export type KeeperMemoryHealthAlertTarget =
  | 'snapshot_read_error'
  | 'source_snapshot_read_error'
  | 'librarian_failures'
  | 'librarian_starvation'
  | 'vision_ingest_errors'

// Mirrors the backend contract: each alert code carries exactly one severity
// (starvation is the only error-level alert). The decoder rejects a payload
// that disagrees.
const KEEPER_MEMORY_HEALTH_ALERT_SEVERITY: Record<
  KeeperMemoryHealthAlertCode,
  KeeperMemoryHealthAlertSeverity
> = {
  snapshot_read_error: 'warn',
  source_snapshot_read_error: 'warn',
  librarian_failures: 'warn',
  librarian_starvation: 'error',
  vision_ingest_errors: 'warn',
}

export interface KeeperMemoryHealthAlert {
  code: KeeperMemoryHealthAlertCode
  severity: KeeperMemoryHealthAlertSeverity
  target: KeeperMemoryHealthAlertTarget
  label: string
  message: string
}

export interface KeeperMemoryHealthVisionErrorReason {
  reason: string
  count: number
}

/** How many bins the server's memory age ladder has (RFC-0515 §2.4.5). */
export const KEEPER_MEMORY_AGE_BIN_COUNT = 24

/**
 * The server's memory age ladder: the ordinary facts counted by the time since
 * each was first seen, {@link KEEPER_MEMORY_AGE_BIN_COUNT} counts, the newest
 * bin (under an hour) first and 30 days or older last. The counts add up to
 * the row's `facts`.
 */
export type KeeperMemoryAgeBins = readonly number[]

/** How many clock hours the server's fact-count trend covers (RFC-0517 §2.2). */
const KEEPER_MEMORY_TREND_HOURS = 168

const SECONDS_PER_HOUR = 3600

/**
 * The facts a Keeper held after the last commit of one clock hour, and when
 * that commit was recorded. A commit that kept the stored snapshot counts the
 * facts it kept, not new claims.
 */
export interface KeeperMemoryFactsAtHour {
  recorded_at: number
  facts: number
}

/** The passes a Keeper Memory commit is counted under, as the server labels them. */
const KEEPER_MEMORY_COMMIT_PASSES = [
  'admission',
  'durable',
  'continuity',
  'cleanup',
  'keeper_write',
  'keeper_delete',
  'operator_delete',
] as const

export type KeeperMemoryCommitPass = typeof KEEPER_MEMORY_COMMIT_PASSES[number]

/** The memory IDs one pass's commits added, absorbed, superseded and dropped. */
export interface KeeperMemoryChangeCounts {
  added: number
  absorbed: number
  superseded: number
  dropped: number
}

const KEEPER_MEMORY_CHANGES: readonly (keyof KeeperMemoryChangeCounts)[] = [
  'added',
  'absorbed',
  'superseded',
  'dropped',
]

/** Every pass's counts since the server started; the counter is not kept across restarts. */
export type KeeperMemoryChangesByPass = Record<KeeperMemoryCommitPass, KeeperMemoryChangeCounts>

export type KeeperMemoryWriterState =
  | 'booting'
  | 'retired'
  | 'idle'
  | 'asking'
  | 'resting'
  | 'refused_at_bottom'
  | 'stopped'
export type KeeperMemoryWriterLevel = 'ok' | 'warn' | 'error'
export type KeeperMemoryWriterAlarm = 'E1' | 'E2' | 'E3' | 'E4' | 'E5' | 'W1' | 'W2' | 'W3'

/** The Keeper's Memory writer as its row carries it under `writer`: the one
 *  that commits to the Keeper's Memory. */
export type KeeperMemoryWriter =
  /** The answering process runs no writer. */
  | { kind: 'none_in_process' }
  /** The Keeper is not in the registry, so no writer is made for it. */
  | { kind: 'no_writer' }
  | {
    kind: 'writer'
    row: {
      state: KeeperMemoryWriterState
      level: KeeperMemoryWriterLevel
      alarms: KeeperMemoryWriterAlarm[]
      stop?: string
      available_acts?: string[]
      pending_molt?: boolean
      pending_molt_categories?: string[]
    }
  }

export interface KeeperMemoryHealthKeeperEntry {
  keeper_id: string
  revision: number
  updated_at: number | null
  facts: number
  observed_facts: number
  derived_facts: number
  support_invalidations: number
  snapshot_bytes: number
  added: number
  removed: number
  snapshot_present: boolean
  age_bins: KeeperMemoryAgeBins | null
  /** Oldest first, one point per clock hour of the last {@link KEEPER_MEMORY_TREND_HOURS}. */
  facts_by_hour: KeeperMemoryFactsAtHour[]
  changes_since_start: KeeperMemoryChangesByPass
  writer: KeeperMemoryWriter
  librarian_failures: number
  vision_ingest_errors: number
  vision_ingest_error_reasons: KeeperMemoryHealthVisionErrorReason[]
  read_error: string | null
  source_revision: number
  source_facts: number
  source_invalidations: number
  source_snapshot_bytes: number
  source_snapshot_present: boolean
  source_read_error: string | null
  alerts: KeeperMemoryHealthAlert[]
}

export interface KeeperMemoryHealthResponse {
  schema: 'keeper.memory_os.current_health.v19'
  generated_at: number
  keepers: KeeperMemoryHealthKeeperEntry[]
  totals: {
    facts: number
    observed_facts: number
    derived_facts: number
    support_invalidations: number
    snapshot_bytes: number
    added: number
    removed: number
    source_facts: number
    source_invalidations: number
    source_snapshot_bytes: number
    librarian_failures: number
    vision_ingest_errors: number
    read_errors: number
    source_read_errors: number
  }
  alert_summary: {
    total_alerts: number
    warn_alerts: number
    error_alerts: number
    keepers_with_alerts: number
    snapshot_read_error_keepers: number
    source_snapshot_read_error_keepers: number
    librarian_starving_keepers: number
  }
}

function exactKeys(raw: Record<string, unknown>, keys: readonly string[]): boolean {
  const observed = Object.keys(raw)
  return observed.length === keys.length && observed.every(key => keys.includes(key))
}

function nonNegativeInteger(raw: unknown): number | null {
  const value = asNumber(raw)
  return value != null && Number.isSafeInteger(value) && value >= 0 ? value : null
}

function finiteNumber(raw: unknown): number | null {
  const value = asNumber(raw)
  return value == null ? null : value
}

function nonEmptyString(raw: unknown): string | null {
  return typeof raw === 'string' && raw.length > 0 ? raw : null
}

function decodeKeeperMemoryHealthAlert(raw: unknown): KeeperMemoryHealthAlert | null {
  if (!isRecord(raw) || !exactKeys(raw, [
    'code',
    'severity',
    'target',
    'label',
    'message',
  ])) return null
  const code =
    raw.code === 'snapshot_read_error'
    || raw.code === 'source_snapshot_read_error'
    || raw.code === 'librarian_failures'
    || raw.code === 'librarian_starvation'
    || raw.code === 'vision_ingest_errors'
      ? raw.code
      : null
  const target =
    raw.target === 'snapshot_read_error'
    || raw.target === 'source_snapshot_read_error'
    || raw.target === 'librarian_failures'
    || raw.target === 'librarian_starvation'
    || raw.target === 'vision_ingest_errors'
      ? raw.target
      : null
  const label = nonEmptyString(raw.label)
  const message = nonEmptyString(raw.message)
  if (
    code === null
    || target === null
    || code !== target
    || raw.severity !== KEEPER_MEMORY_HEALTH_ALERT_SEVERITY[code]
    || label === null
    || message === null
  ) return null
  return {
    code,
    severity: KEEPER_MEMORY_HEALTH_ALERT_SEVERITY[code],
    target,
    label,
    message,
  }
}

function decodeVisionErrorReason(raw: unknown): KeeperMemoryHealthVisionErrorReason | null {
  if (!isRecord(raw) || !exactKeys(raw, ['reason', 'count'])) return null
  const reason = nonEmptyString(raw.reason)
  const count = nonNegativeInteger(raw.count)
  return reason === null || count === null || count === 0 ? null : { reason, count }
}

function decodeKeeperMemoryAgeBins(raw: unknown, expectedFacts: number): KeeperMemoryAgeBins | null {
  if (!Array.isArray(raw) || raw.length !== KEEPER_MEMORY_AGE_BIN_COUNT) return null
  const counts: number[] = []
  for (const item of raw) {
    const count = nonNegativeInteger(item)
    if (count === null) return null
    counts.push(count)
  }
  if (counts.reduce((sum, count) => sum + count, 0) !== expectedFacts) return null
  return counts
}

// Each point stands in a later clock hour than the one before it.
function decodeKeeperMemoryFactsByHour(raw: unknown): KeeperMemoryFactsAtHour[] | null {
  if (!Array.isArray(raw) || raw.length > KEEPER_MEMORY_TREND_HOURS) return null
  const points: KeeperMemoryFactsAtHour[] = []
  let previousHour: number | null = null
  for (const item of raw) {
    if (!isRecord(item) || !exactKeys(item, ['recorded_at', 'facts'])) return null
    const recorded_at = finiteNumber(item.recorded_at)
    const facts = nonNegativeInteger(item.facts)
    if (recorded_at === null || facts === null) return null
    const hour = Math.floor(recorded_at / SECONDS_PER_HOUR)
    if (previousHour !== null && hour <= previousHour) return null
    previousHour = hour
    points.push({ recorded_at, facts })
  }
  return points
}

function decodeKeeperMemoryChangeCounts(raw: unknown): KeeperMemoryChangeCounts | null {
  if (!isRecord(raw) || !exactKeys(raw, KEEPER_MEMORY_CHANGES)) return null
  const added = nonNegativeInteger(raw.added)
  const absorbed = nonNegativeInteger(raw.absorbed)
  const superseded = nonNegativeInteger(raw.superseded)
  const dropped = nonNegativeInteger(raw.dropped)
  if (added === null || absorbed === null || superseded === null || dropped === null) return null
  return { added, absorbed, superseded, dropped }
}

// Every pass the server counts, each with every change: a table from a build
// that counts another pass is refused, not read in part.
function decodeKeeperMemoryChangesByPass(raw: unknown): KeeperMemoryChangesByPass | null {
  if (!isRecord(raw) || !exactKeys(raw, KEEPER_MEMORY_COMMIT_PASSES)) return null
  const admission = decodeKeeperMemoryChangeCounts(raw.admission)
  const durable = decodeKeeperMemoryChangeCounts(raw.durable)
  const continuity = decodeKeeperMemoryChangeCounts(raw.continuity)
  const cleanup = decodeKeeperMemoryChangeCounts(raw.cleanup)
  const keeper_write = decodeKeeperMemoryChangeCounts(raw.keeper_write)
  const keeper_delete = decodeKeeperMemoryChangeCounts(raw.keeper_delete)
  const operator_delete = decodeKeeperMemoryChangeCounts(raw.operator_delete)
  if (
    admission === null
    || durable === null
    || continuity === null
    || cleanup === null
    || keeper_write === null
    || keeper_delete === null
    || operator_delete === null
  ) return null
  return { admission, durable, continuity, cleanup, keeper_write, keeper_delete, operator_delete }
}

const KEEPER_MEMORY_WRITER_STATES: readonly KeeperMemoryWriterState[] = [
  'booting',
  'retired',
  'idle',
  'asking',
  'resting',
  'refused_at_bottom',
  'stopped',
]
const KEEPER_MEMORY_WRITER_LEVELS: readonly KeeperMemoryWriterLevel[] = ['ok', 'warn', 'error']
const KEEPER_MEMORY_WRITER_ALARMS: readonly KeeperMemoryWriterAlarm[] = [
  'E1',
  'E2',
  'E3',
  'E4',
  'E5',
  'W1',
  'W2',
  'W3',
]

function closedToken<T extends string>(raw: unknown, tokens: readonly T[]): T | null {
  return tokens.find(token => token === raw) ?? null
}

function decodeKeeperMemoryWriter(raw: unknown): KeeperMemoryWriter | null {
  if (!isRecord(raw)) return null
  const kind = raw.kind
  if (kind === 'none_in_process' || kind === 'no_writer') {
    return exactKeys(raw, ['kind']) ? { kind } : null
  }
  if (kind !== 'writer' || !exactKeys(raw, ['kind', 'row']) || !isRecord(raw.row)) return null
  const state = closedToken(raw.row.state, KEEPER_MEMORY_WRITER_STATES)
  const level = closedToken(raw.row.level, KEEPER_MEMORY_WRITER_LEVELS)
  const alarms: KeeperMemoryWriterAlarm[] = []
  if (!Array.isArray(raw.row.alarms)) return null
  for (const token of raw.row.alarms) {
    const alarm = closedToken(token, KEEPER_MEMORY_WRITER_ALARMS)
    if (alarm === null) return null
    alarms.push(alarm)
  }
  if (state === null || level === null) return null
  const stop = typeof raw.row.stop === 'string' && raw.row.stop.trim() !== '' ? raw.row.stop : undefined
  const available_acts = Array.isArray(raw.row.available_acts)
    ? raw.row.available_acts.filter((item): item is string => typeof item === 'string' && item.trim() !== '')
    : undefined
  const pending_molt = raw.row.pending_molt !== undefined && raw.row.pending_molt !== null ? true : undefined
  const pending_molt_categories = Array.isArray(raw.row.pending_molt_categories)
    ? raw.row.pending_molt_categories.filter((item): item is string => typeof item === 'string' && item.trim() !== '')
    : undefined
  return {
    kind: 'writer',
    row: {
      state,
      level,
      alarms,
      ...(stop === undefined ? {} : { stop }),
      ...(available_acts === undefined ? {} : { available_acts }),
      ...(pending_molt === undefined ? {} : { pending_molt }),
      ...(pending_molt_categories === undefined ? {} : { pending_molt_categories }),
    },
  }
}

function decodeKeeperMemoryHealthEntry(raw: unknown): KeeperMemoryHealthKeeperEntry | null {
  if (!isRecord(raw) || !exactKeys(raw, [
    'keeper_id',
    'revision',
    'updated_at',
    'facts',
    'observed_facts',
    'derived_facts',
    'support_invalidations',
    'snapshot_bytes',
    'added',
    'removed',
    'snapshot_present',
    'age_bins',
    'facts_by_hour',
    'changes_since_start',
    'writer',
    'librarian_failures',
    'vision_ingest_errors',
    'vision_ingest_error_reasons',
    'read_error',
    'source_revision',
    'source_facts',
    'source_invalidations',
    'source_snapshot_bytes',
    'source_snapshot_present',
    'source_read_error',
    'alerts',
  ])) return null
  const keeper_id = nonEmptyString(raw.keeper_id)
  const revision = nonNegativeInteger(raw.revision)
  const updated_at = raw.updated_at === null ? null : finiteNumber(raw.updated_at)
  const facts = nonNegativeInteger(raw.facts)
  const observed_facts = nonNegativeInteger(raw.observed_facts)
  const derived_facts = nonNegativeInteger(raw.derived_facts)
  const support_invalidations = nonNegativeInteger(raw.support_invalidations)
  const snapshot_bytes = nonNegativeInteger(raw.snapshot_bytes)
  const added = nonNegativeInteger(raw.added)
  const removed = nonNegativeInteger(raw.removed)
  const snapshot_present = typeof raw.snapshot_present === 'boolean'
    ? raw.snapshot_present
    : null
  const facts_by_hour = decodeKeeperMemoryFactsByHour(raw.facts_by_hour)
  const changes_since_start = decodeKeeperMemoryChangesByPass(raw.changes_since_start)
  const writer = decodeKeeperMemoryWriter(raw.writer)
  const librarian_failures = nonNegativeInteger(raw.librarian_failures)
  const vision_ingest_errors = nonNegativeInteger(raw.vision_ingest_errors)
  const vision_ingest_error_reasons = Array.isArray(raw.vision_ingest_error_reasons)
    ? raw.vision_ingest_error_reasons.map(decodeVisionErrorReason)
    : null
  const read_error = raw.read_error === null ? null : nonEmptyString(raw.read_error)
  const source_revision = nonNegativeInteger(raw.source_revision)
  const source_facts = nonNegativeInteger(raw.source_facts)
  const source_invalidations = nonNegativeInteger(raw.source_invalidations)
  const source_snapshot_bytes = nonNegativeInteger(raw.source_snapshot_bytes)
  const source_snapshot_present = typeof raw.source_snapshot_present === 'boolean'
    ? raw.source_snapshot_present
    : null
  const source_read_error = raw.source_read_error === null
    ? null
    : nonEmptyString(raw.source_read_error)
  const alerts = Array.isArray(raw.alerts)
    ? raw.alerts.map(decodeKeeperMemoryHealthAlert)
    : null
  // A ladder needs the fact count it adds up to; without one the row fails below.
  const age_bins = raw.age_bins === null || facts === null
    ? null
    : decodeKeeperMemoryAgeBins(raw.age_bins, facts)
  if (
    keeper_id === null
    || revision === null
    || facts === null
    || observed_facts === null
    || derived_facts === null
    || support_invalidations === null
    || observed_facts + derived_facts !== facts
    || snapshot_bytes === null
    || added === null
    || removed === null
    || snapshot_present === null
    || (raw.updated_at !== null && updated_at === null)
    || (updated_at !== null && updated_at < 0)
    || (updated_at !== null) !== snapshot_present
    || (raw.age_bins !== null && age_bins === null)
    || facts_by_hour === null
    || changes_since_start === null
    || writer === null
    || librarian_failures === null
    || vision_ingest_errors === null
    || vision_ingest_error_reasons === null
    || vision_ingest_error_reasons.some(reason => reason === null)
    || (raw.read_error !== null && read_error === null)
    || source_revision === null
    || source_facts === null
    || source_invalidations === null
    || source_snapshot_bytes === null
    || source_snapshot_present === null
    || (raw.source_read_error !== null && source_read_error === null)
    || alerts === null
    || alerts.some(alert => alert === null)
  ) return null
  const visionReasons = vision_ingest_error_reasons as KeeperMemoryHealthVisionErrorReason[]
  if (
    new Set(visionReasons.map(reason => reason.reason)).size !== visionReasons.length
    || visionReasons.reduce((total, reason) => total + reason.count, 0) !== vision_ingest_errors
  ) return null
  return {
    keeper_id,
    revision,
    updated_at,
    facts,
    observed_facts,
    derived_facts,
    support_invalidations,
    snapshot_bytes,
    added,
    removed,
    snapshot_present,
    age_bins,
    facts_by_hour,
    changes_since_start,
    writer,
    librarian_failures,
    vision_ingest_errors,
    vision_ingest_error_reasons: visionReasons,
    read_error,
    source_revision,
    source_facts,
    source_invalidations,
    source_snapshot_bytes,
    source_snapshot_present,
    source_read_error,
    alerts: alerts as KeeperMemoryHealthAlert[],
  }
}

function decodeKeeperMemoryHealth(raw: unknown): KeeperMemoryHealthResponse | null {
  if (!isRecord(raw)) return null
  if (!exactKeys(raw, ['schema', 'generated_at', 'keepers', 'totals', 'alert_summary'])) return null
  if (raw.schema !== 'keeper.memory_os.current_health.v19') return null
  const generated_at = finiteNumber(raw.generated_at)
  const keepers = Array.isArray(raw.keepers)
    ? raw.keepers.map(decodeKeeperMemoryHealthEntry)
    : null
  if (
    generated_at === null
    || keepers === null
    || keepers.some(entry => entry === null)
    || !isRecord(raw.totals)
    || !isRecord(raw.alert_summary)
  ) return null
  const entries = keepers as KeeperMemoryHealthKeeperEntry[]
  if (new Set(entries.map(entry => entry.keeper_id)).size !== entries.length) return null
  const sum = (field: (entry: KeeperMemoryHealthKeeperEntry) => number) =>
    entries.reduce((total, entry) => total + field(entry), 0)
  const totals = raw.totals
  if (!exactKeys(totals, [
    'facts',
    'observed_facts',
    'derived_facts',
    'support_invalidations',
    'snapshot_bytes',
    'added',
    'removed',
    'source_facts',
    'source_invalidations',
    'source_snapshot_bytes',
    'librarian_failures',
    'vision_ingest_errors',
    'read_errors',
    'source_read_errors',
  ])) return null
  const expectedTotals = {
    facts: sum(entry => entry.facts),
    observed_facts: sum(entry => entry.observed_facts),
    derived_facts: sum(entry => entry.derived_facts),
    support_invalidations: sum(entry => entry.support_invalidations),
    snapshot_bytes: sum(entry => entry.snapshot_bytes),
    added: sum(entry => entry.added),
    removed: sum(entry => entry.removed),
    source_facts: sum(entry => entry.source_facts),
    source_invalidations: sum(entry => entry.source_invalidations),
    source_snapshot_bytes: sum(entry => entry.source_snapshot_bytes),
    librarian_failures: sum(entry => entry.librarian_failures),
    vision_ingest_errors: sum(entry => entry.vision_ingest_errors),
    read_errors: sum(entry => entry.read_error === null ? 0 : 1),
    source_read_errors: sum(entry => entry.source_read_error === null ? 0 : 1),
  }
  if (Object.entries(expectedTotals).some(([key, value]) => totals[key] !== value)) return null
  const alertSummary = raw.alert_summary
  if (!exactKeys(alertSummary, [
    'total_alerts',
    'warn_alerts',
    'error_alerts',
    'keepers_with_alerts',
    'snapshot_read_error_keepers',
    'source_snapshot_read_error_keepers',
    'librarian_starving_keepers',
  ])) return null
  const totalAlerts = sum(entry => entry.alerts.length)
  const countAlertSeverity = (severity: KeeperMemoryHealthAlertSeverity) =>
    sum(entry => entry.alerts.filter(alert => alert.severity === severity).length)
  const expectedAlertSummary = {
    total_alerts: totalAlerts,
    warn_alerts: countAlertSeverity('warn'),
    error_alerts: countAlertSeverity('error'),
    keepers_with_alerts: sum(entry => entry.alerts.length > 0 ? 1 : 0),
    snapshot_read_error_keepers: sum(entry => entry.read_error === null ? 0 : 1),
    source_snapshot_read_error_keepers: sum(entry =>
      entry.source_read_error === null ? 0 : 1),
    librarian_starving_keepers: sum(entry =>
      entry.librarian_failures > 0 && !entry.snapshot_present ? 1 : 0),
  }
  if (
    Object.entries(expectedAlertSummary)
      .some(([key, value]) => alertSummary[key] !== value)
  ) return null
  return {
    schema: raw.schema,
    generated_at,
    keepers: entries,
    totals: expectedTotals,
    alert_summary: expectedAlertSummary,
  }
}

export function fetchKeeperMemoryHealth(opts?: { signal?: AbortSignal }): Promise<KeeperMemoryHealthResponse> {
  return get<unknown>('/api/v1/dashboard/keeper-memory-health', opts).then((raw) => {
    const decoded = decodeKeeperMemoryHealth(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper memory health payload')
    return decoded
  })
}

// --- Verification requests (Mission detail table) ---
// Backend: lib/dashboard/dashboard_verification.ml
// Route:   GET /api/v1/verification/requests?task_id=&limit=
// Shape is stable; status values match the Verification state machine's
// user-visible mapping (pending → approved | rejected, plus a reserved
export interface VerificationRequest {
  request_id: string
  task_id: string
  task_title: string
  created_at: string
  submitted_by: string
  completion_contract: string[]
  required_artifacts: string[]
  submitted_evidence: string[]
  evidence_projection_error: string | null
}

export interface VerificationRequestsResponse {
  updated_at: string
  total: number
  requests: VerificationRequest[]
}

/** Which list the server answers: the requests Tasks are waiting on now, or
 * every submission ever stored. */
export type VerificationRequestsView = 'awaiting' | 'all'

interface FetchVerificationRequestsOptions {
  taskId?: string
  view?: VerificationRequestsView
  limit?: number
  signal?: AbortSignal
}

export function fetchVerificationRequests(
  opts?: FetchVerificationRequestsOptions,
): Promise<VerificationRequestsResponse> {
  const params = new URLSearchParams()
  if (opts?.taskId && opts.taskId.trim() !== '') {
    params.set('task_id', opts.taskId.trim())
  }
  if (opts?.view != null) {
    params.set('view', opts.view)
  }
  if (opts?.limit != null) {
    params.set('limit', String(opts.limit))
  }
  const qs = params.toString()
  const path = qs.length > 0
    ? `/api/v1/verification/requests?${qs}`
    : '/api/v1/verification/requests'
  return get<VerificationRequestsResponse>(path, { signal: opts?.signal })
}

export type TlaSpecCategory = 'boundary' | 'bug-models' | 'other'

export interface TlaSpecEntry {
  name: string
  path: string
  category: TlaSpecCategory
  has_clean_cfg: boolean
  has_buggy_cfg: boolean
  mtime_iso: string
}

export interface TlaSpecsResponse {
  updated_at: string
  specs_dir: string | null
  count: number
  entries: TlaSpecEntry[]
}

export function fetchTlaSpecs(
  opts?: AbortableRequestOptions,
): Promise<TlaSpecsResponse> {
  return get<TlaSpecsResponse>('/api/v1/verification/specs', {
    signal: opts?.signal,
  })
}

export type TlcResultStatus =
  | 'passed'
  | 'violated'
  | 'running'
  | 'error'
  | 'not_run'

export interface TlcResultEntry {
  spec_name: string
  cfg_name: string
  category: TlaSpecCategory
  status: TlcResultStatus
  states_explored: number | null
  distinct_states: number | null
  diameter: number | null
  last_run_at: string | null
  violation: string | null
  log_path: string | null
}

export interface TlcResultsResponse {
  updated_at: string
  results_dir: string | null
  count: number
  entries: TlcResultEntry[]
}

export function fetchTlcResults(
  opts?: AbortableRequestOptions,
): Promise<TlcResultsResponse> {
  return get<TlcResultsResponse>('/api/v1/verification/tlc-results', {
    signal: opts?.signal,
  })
}

export interface AuditEntry {
  id: string
  ts: string
  actor: string
  kind: string
  target?: string
  summary: string
  severity: string
  payload?: unknown
}

export interface AuditLedgerResponse {
  entries: AuditEntry[]
  count: number
}

export interface AuditLedgerParams {
  limit?: number
  actor?: string
  kind?: string
  severity?: string
  since?: number
  until?: number
}

export function fetchAuditLedger(
  params: AuditLedgerParams = {},
  opts?: { signal?: AbortSignal },
): Promise<AuditLedgerResponse> {
  const { limit = 100, actor, kind, severity, since, until } = params
  const qs = new URLSearchParams()
  qs.set('limit', String(limit))
  if (actor) qs.set('actor', actor)
  if (kind) qs.set('kind', kind)
  if (severity) qs.set('severity', severity)
  if (since != null) qs.set('since', String(since))
  if (until != null) qs.set('until', String(until))
  return get<AuditLedgerResponse>(`/api/v1/audit?${qs.toString()}`, {
    signal: opts?.signal,
  })
}

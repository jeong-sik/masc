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
  | 'librarian_lane_busy'
  | 'librarian_failures'
  | 'librarian_starvation'
  | 'vision_ingest_errors'

export type KeeperMemoryHealthAlertSeverity = 'warn' | 'error'

export type KeeperMemoryHealthAlertTarget =
  | 'snapshot_read_error'
  | 'source_snapshot_read_error'
  | 'librarian_lane_busy'
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
  librarian_lane_busy: 'warn',
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
  value: number
  threshold: number
}

export interface KeeperMemoryHealthVisionErrorReason {
  reason: string
  count: number
}

export interface KeeperMemoryHealthKeeperEntry {
  keeper_id: string
  revision: number
  facts: number
  observed_facts: number
  derived_facts: number
  support_invalidations: number
  snapshot_bytes: number
  added: number
  removed: number
  snapshot_present: boolean
  librarian_lane_busy: number
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
  schema: string
  generated_at: number
  cadence_counter_entries: number
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
    librarian_lane_busy: number
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
    librarian_lane_busy_keepers: number
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
    'value',
    'threshold',
  ])) return null
  const code =
    raw.code === 'snapshot_read_error'
    || raw.code === 'source_snapshot_read_error'
    || raw.code === 'librarian_lane_busy'
    || raw.code === 'librarian_failures'
    || raw.code === 'librarian_starvation'
    || raw.code === 'vision_ingest_errors'
      ? raw.code
      : null
  const target =
    raw.target === 'snapshot_read_error'
    || raw.target === 'source_snapshot_read_error'
    || raw.target === 'librarian_lane_busy'
    || raw.target === 'librarian_failures'
    || raw.target === 'librarian_starvation'
    || raw.target === 'vision_ingest_errors'
      ? raw.target
      : null
  const label = nonEmptyString(raw.label)
  const message = nonEmptyString(raw.message)
  const value = finiteNumber(raw.value)
  const threshold = finiteNumber(raw.threshold)
  if (
    code === null
    || target === null
    || code !== target
    || raw.severity !== KEEPER_MEMORY_HEALTH_ALERT_SEVERITY[code]
    || label === null
    || message === null
    || value === null
    || threshold === null
  ) return null
  return {
    code,
    severity: KEEPER_MEMORY_HEALTH_ALERT_SEVERITY[code],
    target,
    label,
    message,
    value,
    threshold,
  }
}

function decodeVisionErrorReason(raw: unknown): KeeperMemoryHealthVisionErrorReason | null {
  if (!isRecord(raw) || !exactKeys(raw, ['reason', 'count'])) return null
  const reason = nonEmptyString(raw.reason)
  const count = nonNegativeInteger(raw.count)
  return reason === null || count === null || count === 0 ? null : { reason, count }
}

function decodeKeeperMemoryHealthEntry(raw: unknown): KeeperMemoryHealthKeeperEntry | null {
  if (!isRecord(raw) || !exactKeys(raw, [
    'keeper_id',
    'revision',
    'facts',
    'observed_facts',
    'derived_facts',
    'support_invalidations',
    'snapshot_bytes',
    'added',
    'removed',
    'snapshot_present',
    'librarian_lane_busy',
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
  const librarian_lane_busy = nonNegativeInteger(raw.librarian_lane_busy)
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
    || librarian_lane_busy === null
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
    facts,
    observed_facts,
    derived_facts,
    support_invalidations,
    snapshot_bytes,
    added,
    removed,
    snapshot_present,
    librarian_lane_busy,
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
  if (!isRecord(raw) || !exactKeys(raw, [
    'schema',
    'generated_at',
    'cadence_counter_entries',
    'keepers',
    'totals',
    'alert_summary',
  ])) return null
  if (raw.schema !== 'keeper.memory_os.current_health.v3') return null
  const generated_at = finiteNumber(raw.generated_at)
  const cadence_counter_entries = nonNegativeInteger(raw.cadence_counter_entries)
  const keepers = Array.isArray(raw.keepers)
    ? raw.keepers.map(decodeKeeperMemoryHealthEntry)
    : null
  if (
    generated_at === null
    || cadence_counter_entries === null
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
    'librarian_lane_busy',
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
    librarian_lane_busy: sum(entry => entry.librarian_lane_busy),
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
    'librarian_lane_busy_keepers',
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
    librarian_lane_busy_keepers: sum(entry => entry.librarian_lane_busy > 0 ? 1 : 0),
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
    cadence_counter_entries,
    keepers: entries,
    totals: expectedTotals,
    alert_summary: expectedAlertSummary,
  }
}

export function fetchKeeperMemoryHealth(): Promise<KeeperMemoryHealthResponse> {
  return get<unknown>('/api/v1/dashboard/keeper-memory-health').then((raw) => {
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

interface FetchVerificationRequestsOptions {
  taskId?: string
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
  | 'queued'
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

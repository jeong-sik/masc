// MASC Dashboard — Misc projections: memory subsystems /
// keeper memory health / verification requests / TLA specs+TLC results / audit.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { isRecord } from '../lib/type-guards'

// --- Memory Subsystems ---

export interface MemorySubsystemsDelegationRequest {
  id: string
  requester: string
  topic: string
  promotion_state: string
  dir: string
  json_path: string
  task_seed_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsResponse {
  generated_at: string
  delegation_requests?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDelegationRequest[]
    error?: string | null
  }
}

interface MemorySubsystemsQuery {
  limit?: number
  signal?: AbortSignal
}

export function fetchMemorySubsystems(
  opts?: MemorySubsystemsQuery,
): Promise<MemorySubsystemsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit != null) params.set('limit', String(opts.limit))
  const qs = params.toString()
  return get<MemorySubsystemsResponse>(
    `/api/v1/dashboard/memory-subsystems${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

// --- Keeper Memory Health ---

export type KeeperMemoryHealthAlertCode = 'duplicate_claim_identity_rows'

export type KeeperMemoryHealthAlertSeverity = 'warn'

export type KeeperMemoryHealthAlertTarget = 'duplicate_claim_identity_rows'

export interface KeeperMemoryHealthAlert {
  code: KeeperMemoryHealthAlertCode
  severity: KeeperMemoryHealthAlertSeverity
  target: KeeperMemoryHealthAlertTarget
  label: string
  message: string
  value: number
  threshold: number
}

export interface KeeperMemoryHealthKeeperEntry {
  keeper_id: string
  facts: number
  facts_bytes: number
  events: number
  events_bytes: number
  events_bytes_to_facts_bytes_ratio: number
  duplicate_claim_identity_rows: number
  alerts: KeeperMemoryHealthAlert[]
}

export interface KeeperMemoryHealthReadError {
  keeper_id: string
  error: string
}

export interface KeeperMemoryHealthResponse {
  generated_at: number
  cadence_counter_entries: number
  read_error_count: number
  read_errors: KeeperMemoryHealthReadError[]
  keepers: KeeperMemoryHealthKeeperEntry[]
  totals: {
    facts: number
    facts_bytes: number
    events_bytes: number
    duplicate_claim_identity_rows: number
  }
  alert_summary: {
    total_alerts: number
    warn_alerts: number
    keepers_with_alerts: number
    duplicate_claim_identity_rows_keepers: number
    thresholds: {
      duplicate_claim_identity_rows: number
    }
  }
}

function hasExactKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

function decodeNonEmptyString(raw: unknown): string | null {
  return typeof raw === 'string' && raw.length > 0 ? raw : null
}

function decodeNonNegativeInteger(raw: unknown): number | null {
  return typeof raw === 'number' && Number.isSafeInteger(raw) && raw >= 0
    ? raw
    : null
}

function decodeNonNegativeNumber(raw: unknown): number | null {
  return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0
    ? raw
    : null
}

function decodeExactArray<T>(
  raw: unknown,
  decode: (item: unknown) => T | null,
): T[] | null {
  if (!Array.isArray(raw)) return null
  const decoded = raw.map(decode)
  return decoded.every((item): item is T => item !== null) ? decoded : null
}

function decodeKeeperMemoryHealthAlertCode(raw: unknown): KeeperMemoryHealthAlertCode | null {
  switch (raw) {
    case 'duplicate_claim_identity_rows':
      return raw
    default:
      return null
  }
}

function decodeKeeperMemoryHealthAlert(raw: unknown): KeeperMemoryHealthAlert | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'code',
    'severity',
    'target',
    'label',
    'message',
    'value',
    'threshold',
  ])) return null
  const code = decodeKeeperMemoryHealthAlertCode(raw.code)
  const target = decodeKeeperMemoryHealthAlertCode(raw.target)
  const label = decodeNonEmptyString(raw.label)
  const message = decodeNonEmptyString(raw.message)
  const value = decodeNonNegativeNumber(raw.value)
  const threshold = decodeNonNegativeNumber(raw.threshold)
  if (
    code === null
    || raw.severity !== 'warn'
    || target === null
    || target !== code
    || label === null
    || message === null
    || value === null
    || threshold === null
  ) return null
  return { code, severity: 'warn', target, label, message, value, threshold }
}

function decodeKeeperMemoryHealthEntry(raw: unknown): KeeperMemoryHealthKeeperEntry | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'keeper_id',
    'facts',
    'facts_bytes',
    'events',
    'events_bytes',
    'events_bytes_to_facts_bytes_ratio',
    'duplicate_claim_identity_rows',
    'alerts',
  ])) return null
  const keeper_id = decodeNonEmptyString(raw.keeper_id)
  const facts = decodeNonNegativeInteger(raw.facts)
  const facts_bytes = decodeNonNegativeInteger(raw.facts_bytes)
  const events = decodeNonNegativeInteger(raw.events)
  const events_bytes = decodeNonNegativeInteger(raw.events_bytes)
  const events_bytes_to_facts_bytes_ratio =
    decodeNonNegativeNumber(raw.events_bytes_to_facts_bytes_ratio)
  const duplicate_claim_identity_rows =
    decodeNonNegativeInteger(raw.duplicate_claim_identity_rows)
  const alerts = decodeExactArray(raw.alerts, decodeKeeperMemoryHealthAlert)
  if (
    keeper_id === null
    || facts === null
    || facts_bytes === null
    || events === null
    || events_bytes === null
    || events_bytes_to_facts_bytes_ratio === null
    || duplicate_claim_identity_rows === null
    || alerts === null
  ) return null
  return {
    keeper_id,
    facts,
    facts_bytes,
    events,
    events_bytes,
    events_bytes_to_facts_bytes_ratio,
    duplicate_claim_identity_rows,
    alerts,
  }
}

function decodeKeeperMemoryHealthReadError(raw: unknown): KeeperMemoryHealthReadError | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['keeper_id', 'error'])) return null
  const keeper_id = decodeNonEmptyString(raw.keeper_id)
  const error = decodeNonEmptyString(raw.error)
  return keeper_id === null || error === null ? null : { keeper_id, error }
}

function decodeKeeperMemoryHealthTotals(
  raw: unknown,
): KeeperMemoryHealthResponse['totals'] | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'facts',
    'facts_bytes',
    'events_bytes',
    'duplicate_claim_identity_rows',
  ])) return null
  const facts = decodeNonNegativeInteger(raw.facts)
  const facts_bytes = decodeNonNegativeInteger(raw.facts_bytes)
  const events_bytes = decodeNonNegativeInteger(raw.events_bytes)
  const duplicate_claim_identity_rows =
    decodeNonNegativeInteger(raw.duplicate_claim_identity_rows)
  if (
    facts === null
    || facts_bytes === null
    || events_bytes === null
    || duplicate_claim_identity_rows === null
  ) return null
  return {
    facts,
    facts_bytes,
    events_bytes,
    duplicate_claim_identity_rows,
  }
}

function decodeKeeperMemoryHealthAlertSummary(
  raw: unknown,
): KeeperMemoryHealthResponse['alert_summary'] | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'total_alerts',
    'warn_alerts',
    'keepers_with_alerts',
    'duplicate_claim_identity_rows_keepers',
    'thresholds',
  ])) return null
  const thresholds = raw.thresholds
  if (!isRecord(thresholds)
    || !hasExactKeys(thresholds, ['duplicate_claim_identity_rows'])) return null
  const total_alerts = decodeNonNegativeInteger(raw.total_alerts)
  const warn_alerts = decodeNonNegativeInteger(raw.warn_alerts)
  const keepers_with_alerts = decodeNonNegativeInteger(raw.keepers_with_alerts)
  const duplicate_claim_identity_rows_keepers =
    decodeNonNegativeInteger(raw.duplicate_claim_identity_rows_keepers)
  const duplicate_claim_identity_rows =
    decodeNonNegativeNumber(thresholds.duplicate_claim_identity_rows)
  if (
    total_alerts === null
    || warn_alerts === null
    || keepers_with_alerts === null
    || duplicate_claim_identity_rows_keepers === null
    || duplicate_claim_identity_rows === null
  ) return null
  return {
    total_alerts,
    warn_alerts,
    keepers_with_alerts,
    duplicate_claim_identity_rows_keepers,
    thresholds: {
      duplicate_claim_identity_rows,
    },
  }
}

function decodeKeeperMemoryHealthResponse(raw: unknown): KeeperMemoryHealthResponse | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'generated_at',
    'cadence_counter_entries',
    'read_error_count',
    'read_errors',
    'keepers',
    'totals',
    'alert_summary',
  ])) return null
  const generated_at = decodeNonNegativeNumber(raw.generated_at)
  const cadence_counter_entries = decodeNonNegativeInteger(raw.cadence_counter_entries)
  const read_error_count = decodeNonNegativeInteger(raw.read_error_count)
  const read_errors = decodeExactArray(raw.read_errors, decodeKeeperMemoryHealthReadError)
  const keepers = decodeExactArray(raw.keepers, decodeKeeperMemoryHealthEntry)
  const totals = decodeKeeperMemoryHealthTotals(raw.totals)
  const alert_summary = decodeKeeperMemoryHealthAlertSummary(raw.alert_summary)
  if (
    generated_at === null
    || cadence_counter_entries === null
    || read_error_count === null
    || read_errors === null
    || read_error_count !== read_errors.length
    || keepers === null
    || totals === null
    || alert_summary === null
  ) return null
  const sum = (
    select: (entry: KeeperMemoryHealthKeeperEntry) => number,
  ): number => keepers.reduce((total, entry) => total + select(entry), 0)
  if (
    totals.facts !== sum(entry => entry.facts)
    || totals.facts_bytes !== sum(entry => entry.facts_bytes)
    || totals.events_bytes !== sum(entry => entry.events_bytes)
    || totals.duplicate_claim_identity_rows
      !== sum(entry => entry.duplicate_claim_identity_rows)
    || keepers.some(entry =>
      entry.events_bytes_to_facts_bytes_ratio
        !== entry.events_bytes / Math.max(1, entry.facts_bytes))
  ) return null
  const keeperIds = new Set(keepers.map(entry => entry.keeper_id))
  const readErrorKeeperIds = new Set(read_errors.map(entry => entry.keeper_id))
  if (
    keeperIds.size !== keepers.length
    || readErrorKeeperIds.size !== read_errors.length
    || [...keeperIds].some(keeperId => readErrorKeeperIds.has(keeperId))
  ) return null
  const alertCodes: readonly KeeperMemoryHealthAlertCode[] = [
    'duplicate_claim_identity_rows',
  ]
  const metricFor = (
    entry: KeeperMemoryHealthKeeperEntry,
    code: KeeperMemoryHealthAlertCode,
  ): number => entry[code]
  const thresholdFor = (code: KeeperMemoryHealthAlertCode): number =>
    alert_summary.thresholds[code]
  if (keepers.some(entry => {
    const seen = new Set<KeeperMemoryHealthAlertCode>()
    for (const alert of entry.alerts) {
      if (
        seen.has(alert.code)
        || alert.target !== alert.code
        || alert.value !== metricFor(entry, alert.code)
        || alert.threshold !== thresholdFor(alert.code)
      ) return true
      seen.add(alert.code)
    }
    return alertCodes.some(code =>
      seen.has(code) !== (metricFor(entry, code) > thresholdFor(code)))
  })) return null
  const allAlerts = keepers.flatMap(entry => entry.alerts)
  const alertCount = (code: KeeperMemoryHealthAlertCode): number =>
    allAlerts.filter(alert => alert.code === code).length
  if (
    alert_summary.total_alerts !== allAlerts.length
    || alert_summary.warn_alerts !== allAlerts.length
    || alert_summary.keepers_with_alerts
      !== keepers.filter(entry => entry.alerts.length > 0).length
    || alert_summary.duplicate_claim_identity_rows_keepers
      !== alertCount('duplicate_claim_identity_rows')
  ) return null
  return {
    generated_at,
    cadence_counter_entries,
    read_error_count,
    read_errors,
    keepers,
    totals,
    alert_summary,
  }
}

export function fetchKeeperMemoryHealth(): Promise<KeeperMemoryHealthResponse> {
  return get<unknown>('/api/v1/dashboard/keeper-memory-health').then((raw) => {
    const decoded = decodeKeeperMemoryHealthResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper memory health payload')
    return decoded
  })
}

// --- Audit Integrity ---
// Backend: lib/server/server_dashboard_http_audit_integrity.ml
// Route:   GET /api/v1/dashboard/audit-integrity
// Read-only snapshot of the Shared_audit hash-chain verification over the
// per-keeper resilience audit logs.

export interface AuditIntegrityKeeperEntry {
  keeper_id: string
  entries: number
  ok: boolean
  broken_at: number | null
  detail: string | null
}

export interface AuditIntegrityResponse {
  generated_at: number
  resilience_enabled: boolean
  keepers: AuditIntegrityKeeperEntry[]
  totals: {
    keepers: number
    entries: number
    ok: number
    failed: number
  }
}

export function fetchAuditIntegrity(): Promise<AuditIntegrityResponse> {
  return get<AuditIntegrityResponse>('/api/v1/dashboard/audit-integrity')
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
  request_kind: 'normal' | 'conflict_triage'
  request_summary: string
  next_action: string | null
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

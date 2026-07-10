// MASC Dashboard — Misc projections: excuse patterns / memory subsystems /
// keeper memory health / verification requests / TLA specs+TLC results / audit.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, type AbortableRequestOptions } from './core'

// --- Excuse Patterns ---

export type ExcusePattern = [string, string]

export function fetchExcusePatterns(): Promise<ExcusePattern[]> {
  return get<ExcusePattern[]>('/api/v1/dashboard/config/excuse-patterns')
}

export function updateExcusePatterns(patterns: ExcusePattern[]): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/dashboard/config/excuse-patterns', patterns)
}

// --- Memory Subsystems ---

export interface MemorySubsystemsSynapse {
  from_agent: string
  to_agent: string
  weight: number
  success_count: number
  failure_count: number
  last_updated: number
  created_at: number
  /** Newest-first list of (unix ts seconds, weight) points, capped at 30.
      Missing for graphs produced by pre-sparkline backends. */
  weight_history?: Array<[number, number]>
}

export interface MemorySubsystemsEpisode {
  id: string
  timestamp: number
  participants: string[]
  event_type: string
  summary: string
  outcome: string
  learnings: string[]
  context: Record<string, string>
}

export interface MemorySubsystemsMemoryEntry {
  keeper: string
  kind: string
  text: string
  priority: number
  ts_unix: number
}

/** RFC-0149 §3.1 — per-keeper memory bank read failure, surfaced as
 *  a typed sibling field next to the entry rows.  `error_class` is one
 *  of the closed 4-value `Keeper_memory_recall_exn_class.t` labels
 *  (`yojson_parse_error | io_error | type_error | other`). */
export interface MemorySubsystemsMemoryEntryError {
  keeper: string
  error_class: string
}

export interface MemorySubsystemsUserModelItem {
  keeper: string
  kind: 'preference' | 'constraint' | string
  claim: string
  source_ref: string
  source_trace_id: string
  source_turn: number
  first_seen: number
  last_verified_at: number | null
  observed_by: string[]
}

export interface MemorySubsystemsUserModelError {
  keeper: string
  error: string
}

export interface MemorySubsystemsUserModelPrompt {
  enabled: boolean
  block_id: string
  injection: string
  runtime_hook: string
  producer?: string
}

export interface MemorySubsystemsDraftSkillCandidate {
  id: string
  agent_name: string
  source_kind: string
  source_ref: string
  promotion_state: string
  dir: string
  json_path: string
  toml_path: string
  skill_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsDelegationRequest {
  id: string
  requester: string
  topic: string
  goal: string | null
  promotion_state: string
  dir: string
  json_path: string
  task_seed_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsResponse {
  generated_at: string
  hebbian: {
    synapses: MemorySubsystemsSynapse[]
    last_consolidation: number
  }
  episodes: {
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsEpisode[]
  }
  memory_entries?: {
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsMemoryEntry[]
    /** RFC-0149 §3.1 — per-keeper memory bank read failures.  Each
     *  entry means that keeper's `memory.jsonl` could not be read and
     *  the corresponding rows are absent from `items`; the rest of
     *  `items` is still trustworthy. */
    errors?: MemorySubsystemsMemoryEntryError[]
  }
  user_model?: {
    schema: string
    source: string
    prompt?: MemorySubsystemsUserModelPrompt
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsUserModelItem[]
    errors?: MemorySubsystemsUserModelError[]
  }
  draft_skill_candidates?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDraftSkillCandidate[]
    error?: string | null
  }
  delegation_requests?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDelegationRequest[]
    error?: string | null
  }
  filters: {
    keepers: string[]
    outcomes: string[]
    memory_kinds?: string[]
  }
}

interface MemorySubsystemsQuery {
  limit?: number
  keeper?: string
  outcome?: string
  q?: string
  includeMemoryEntries?: boolean
  signal?: AbortSignal
}

export function fetchMemorySubsystems(
  opts?: MemorySubsystemsQuery,
): Promise<MemorySubsystemsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit != null) params.set('limit', String(opts.limit))
  if (opts?.keeper) params.set('keeper', opts.keeper)
  if (opts?.outcome) params.set('outcome', opts.outcome)
  if (opts?.q) params.set('q', opts.q)
  if (opts?.includeMemoryEntries) params.set('include_memory_entries', 'true')
  const qs = params.toString()
  return get<MemorySubsystemsResponse>(
    `/api/v1/dashboard/memory-subsystems${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

// --- Keeper Memory Health ---

export type KeeperMemoryHealthAlertCode =
  | 'ttl_expired_on_disk'
  | 'near_duplicate'
  | 'events_to_facts_ratio_high'

export type KeeperMemoryHealthAlertSeverity = 'warn'

export type KeeperMemoryHealthAlertTarget =
  | 'ttl_expired_on_disk'
  | 'near_duplicate'
  | 'events_to_facts_ratio'

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
  events_to_facts_ratio: number
  ttl_expired_on_disk: number
  near_duplicate: number
  alerts: KeeperMemoryHealthAlert[]
}

export interface KeeperMemoryHealthResponse {
  generated_at: number
  cadence_clock: 'keeper_turn_id'
  keepers: KeeperMemoryHealthKeeperEntry[]
  totals: {
    facts: number
    facts_bytes: number
    events_bytes: number
    ttl_expired_on_disk: number
    near_duplicate: number
  }
  alert_summary: {
    total_alerts: number
    warn_alerts: number
    keepers_with_alerts: number
    ttl_expired_keepers: number
    near_duplicate_keepers: number
    high_event_ratio_keepers: number
    thresholds: {
      ttl_expired_on_disk: number
      near_duplicate: number
      events_to_facts_ratio: number
    }
  }
}

export function fetchKeeperMemoryHealth(): Promise<KeeperMemoryHealthResponse> {
  return get<KeeperMemoryHealthResponse>('/api/v1/dashboard/keeper-memory-health')
}

// --- Verification requests (Mission detail table) ---
// Backend: lib/dashboard/dashboard_verification.ml
// Route:   GET /api/v1/verification/requests?task_id=&limit=
// Shape is stable; status values match the Verification state machine's
// user-visible mapping (pending → approved | rejected, plus a reserved
// timed_out slot for the deadline watcher).

export type VerificationRequestStatus =
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'timed_out'

export type VerificationRequestVerdict = 'pass' | 'fail' | 'partial' | null

export interface VerificationRequest {
  request_id: string
  task_id: string
  task_title: string
  request_kind: 'normal' | 'conflict_triage'
  request_summary: string
  next_action: string | null
  keeper: string | null
  status: VerificationRequestStatus
  created_at: string
  submitted_by: string
  approved_by: string | null
  completion_contract: string[]
  required_evidence: string[]
  verdict: VerificationRequestVerdict
  verdict_reason: string
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

interface ResolveVerificationRequestOptions {
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  reason?: string
}

interface ResolveVerificationResponse {
  ok: boolean
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  verifier: string
}

export function resolveVerificationRequest(
  opts: ResolveVerificationRequestOptions,
): Promise<ResolveVerificationResponse> {
  return post<ResolveVerificationResponse>('/api/v1/verification/resolve', {
    task_id: opts.task_id,
    verification_id: opts.verification_id,
    decision: opts.decision,
    reason: opts.reason ?? '',
  })
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

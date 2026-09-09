// MASC Dashboard — Keeper lifecycle (boot/shutdown/reset/clear/checkpoints/pause/resume/wake/bulk) (split from keeper.ts)

import { isRecord } from '../components/common/normalize'
import { isAbortError } from '../lib/async-state'
import {
  fetchControlPlane,
  fetchWithTimeout,
  jsonHeaders,
  DEFAULT_GET_TIMEOUT_MS,
} from './core'

// --- Keeper lifecycle (boot / shutdown) ---

interface KeeperLifecycleResponse {
  ok: boolean
  action?: 'boot' | 'shutdown' | 'reset' | 'clear' | 'pause' | 'resume' | 'wakeup'
  name?: string
  detail?: unknown
  error?: string
  committed?: boolean
}
interface KeeperControlOptions {
  signal?: AbortSignal
}
interface KeeperResumeOptions extends KeeperControlOptions {
  operatorOperationId?: string
}

interface PendingResumeIntent {
  operatorOperationId: string
}

const pendingResumeIntents = new Map<string, PendingResumeIntent>()

function createResumeOperationId(): string {
  return `dashboard-resume-${crypto.randomUUID()}`
}

function resumeIntent(
  name: string,
  explicitOperationId?: string,
): PendingResumeIntent {
  if (explicitOperationId) {
    return { operatorOperationId: explicitOperationId }
  }
  const pending = pendingResumeIntents.get(name)
  if (pending) return pending
  const created = { operatorOperationId: createResumeOperationId() }
  pendingResumeIntents.set(name, created)
  return created
}

function clearCommittedResumeIntent(name: string, intent: PendingResumeIntent): void {
  const pending = pendingResumeIntents.get(name)
  if (pending?.operatorOperationId === intent.operatorOperationId) {
    pendingResumeIntents.delete(name)
  }
}

async function safeJsonResponse<T>(resp: Response, fallbackError: string): Promise<T> {
  try {
    const body = await resp.text()
    if (!body.trim()) {
      return resp.ok
        ? ({ ok: true } as T)
        : ({ ok: false, error: `${fallbackError} (HTTP ${resp.status})` } as T)
    }

    try {
      return JSON.parse(body) as T
    } catch {
      return resp.ok
        ? ({ ok: true, detail: body } as T)
        : ({ ok: false, error: `${fallbackError} (HTTP ${resp.status}): ${body}` } as T)
    }
  } catch {
    return { ok: false, error: `${fallbackError} (HTTP ${resp.status})` } as T
  }
}

async function safeKeeperLifecycle(
  url: string,
  fallbackError: string,
  init?: RequestInit,
): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetchControlPlane(url, {
      method: 'POST',
      headers: jsonHeaders(),
      ...init,
    })
    const payload = await safeJsonResponse<KeeperLifecycleResponse>(resp, fallbackError)
    if (resp.ok) return payload

    const error =
      isRecord(payload) &&
      typeof payload.error === 'string' &&
      payload.error.trim() !== ''
        ? payload.error
        : `${fallbackError} (HTTP ${resp.status})`

    if (isRecord(payload)) {
      return { ...payload, ok: false, error }
    }

    return { ok: false, error }
  } catch (err) {
    if (isAbortError(err)) throw err
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

async function safeKeeperPostWithBody(
  url: string,
  body: Record<string, unknown>,
  fallbackError: string,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetchControlPlane(url, {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify(body),
      signal: opts.signal,
    })
    const payload = await safeJsonResponse<KeeperLifecycleResponse>(resp, fallbackError)
    if (resp.ok) return payload

    const error =
      isRecord(payload) &&
      typeof payload.error === 'string' &&
      payload.error.trim() !== ''
        ? payload.error
        : `${fallbackError} (HTTP ${resp.status})`

    if (isRecord(payload)) {
      return { ...payload, ok: false, error }
    }

    return { ok: false, error }
  } catch (err) {
    if (isAbortError(err)) throw err
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

export function bootKeeper(
  name: string,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/boot`,
    `Failed to boot ${name}`,
    { signal: opts.signal },
  )
}

export function shutdownKeeper(
  name: string,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/shutdown`,
    `Failed to shut down ${name}`,
    { signal: opts.signal },
  )
}

export function resetKeeper(
  name: string,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/reset`,
    `Failed to reset ${name}`,
    { signal: opts.signal },
  )
}

interface KeeperClearRequest {
  reason: string
  preserve_system_prompt?: boolean
}

export function clearKeeper(
  name: string,
  payload: KeeperClearRequest,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/clear`,
    `Failed to clear ${name}`,
    {
      body: JSON.stringify(payload),
      signal: opts.signal,
    },
  )
}

export interface KeeperCheckpointSummary {
  snapshot_id: string
  source_kind: 'agent_core_current' | 'agent_core_history' | string
  is_current: boolean
  path: string
  created_at: number
  generation: number
  message_count: number
  system_prompt_present: boolean
  latest_preview: string | null
  file_stat: {
    size_bytes?: number
    mtime?: number
  } | null
}

export interface KeeperCheckpointCurrentError {
  kind: 'store_error' | 'parse_error' | 'io_error' | 'agent_core_error' | string
  detail: string
}

export interface KeeperCheckpointHistoryError {
  snapshot_id: string
  source_kind: 'agent_core_history' | string
  is_current: false
  path: string
  file_stat: {
    size_bytes?: number
    mtime?: number
  } | null
  status: 'missing' | 'unavailable'
  error_kind: 'not_found' | 'store_error' | 'parse_error' | 'io_error' | 'agent_core_error' | string
  error_detail: string | null
}

export interface KeeperCheckpointInventory {
  keeper: string
  trace_id: string
  session_dir: string
  current: KeeperCheckpointSummary | null
  current_status: 'available' | 'missing' | 'unavailable'
  current_error: KeeperCheckpointCurrentError | null
  history: KeeperCheckpointSummary[]
  history_errors: KeeperCheckpointHistoryError[]
}

interface KeeperCheckpointDeleteResponse {
  ok: boolean
  action: 'delete_history' | string
  keeper: string
  deleted_snapshot_ids: string[]
  missing_snapshot_ids: string[]
  inventory: KeeperCheckpointInventory
}

export interface KeeperCheckpointPurgeReport {
  messages_before: number
  messages_after: number
  bytes_before: number
  bytes_after: number
  bytes_removed: number
  duplicates_dropped: number
  reasoning_blocks_stripped: number
  reasoning_messages_dropped: number
  tool_results_cleared: number
}

export interface KeeperCheckpointPurgeResponse {
  schema: 'masc.keeper_checkpoint_purge.v1'
  ok: true
  action: 'preview_purge' | 'apply_purge'
  keeper: string
  trace_id: string
  apply_allowed: boolean
  applied: boolean
  backup_path: string | null
  report: KeeperCheckpointPurgeReport
  warnings: string[]
  inventory: KeeperCheckpointInventory
}

export async function fetchKeeperCheckpoints(
  name: string,
): Promise<KeeperCheckpointInventory> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/checkpoints`,
    {
      method: 'GET',
      headers: jsonHeaders(),
    },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText)
    throw new Error(`${name} 의 checkpoint 로드 실패 (${resp.status}): ${text}`)
  }
  return resp.json() as Promise<KeeperCheckpointInventory>
}

export async function deleteKeeperHistorySnapshots(
  name: string,
  snapshotIds: string[],
): Promise<KeeperCheckpointDeleteResponse> {
  const resp = await fetch(
    `/api/v1/keepers/${encodeURIComponent(name)}/checkpoints`,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({
        action: 'delete_history',
        snapshot_ids: snapshotIds,
      }),
    },
  )
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText)
    throw new Error(`${name} 의 checkpoint history 삭제 실패 (${resp.status}): ${text}`)
  }
  return resp.json() as Promise<KeeperCheckpointDeleteResponse>
}

async function requestKeeperCheckpointPurge(
  name: string,
  action: 'preview_purge' | 'apply_purge',
): Promise<KeeperCheckpointPurgeResponse> {
  const path = `/api/v1/keepers/${encodeURIComponent(name)}/checkpoints`
  const resp = await fetchControlPlane(path, {
    method: 'POST',
    headers: jsonHeaders(),
    body: JSON.stringify({ action }),
  })
  if (!resp.ok) {
    const payload = await safeJsonResponse<{ error?: string }>(
      resp,
      `${name} checkpoint purge 실패`,
    )
    throw new Error(
      typeof payload.error === 'string' && payload.error.trim() !== ''
        ? payload.error
        : `${name} checkpoint purge 실패 (HTTP ${resp.status})`,
    )
  }
  return resp.json() as Promise<KeeperCheckpointPurgeResponse>
}

export function previewKeeperCheckpointPurge(
  name: string,
): Promise<KeeperCheckpointPurgeResponse> {
  return requestKeeperCheckpointPurge(name, 'preview_purge')
}

export function applyKeeperCheckpointPurge(
  name: string,
): Promise<KeeperCheckpointPurgeResponse> {
  return requestKeeperCheckpointPurge(name, 'apply_purge')
}

export function pauseKeeper(
  name: string,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'pause' },
    `Failed to pause ${name}`,
    opts,
  )
}

export async function resumeKeeper(
  name: string,
  opts: KeeperResumeOptions = {},
): Promise<KeeperLifecycleResponse> {
  const intent = resumeIntent(name, opts.operatorOperationId)
  const result = await safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    {
      action: 'resume',
      operator_operation_id: intent.operatorOperationId,
    },
    `Failed to resume ${name}`,
    opts,
  )
  if (result.ok) clearCommittedResumeIntent(name, intent)
  // Resume_owner commits the durable pause disposition before projecting the
  // live lane. If projection is ambiguous or temporarily unavailable, the
  // pause is already cleared and boot is the safe committed follow-up.
  if (!result.ok && result.committed === true) {
    const boot = await bootKeeper(name, opts)
    return { ...boot, committed: true }
  }
  return result
}

export function wakeKeeper(
  name: string,
  opts: KeeperControlOptions = {},
): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'wakeup' },
    `Failed to wake ${name}`,
    opts,
  )
}

export type BulkKeeperDirectiveAction = 'pause' | 'resume' | 'wakeup'

export interface BulkKeeperResumeTarget {
  name: string
  operatorOperationId?: string
}

export interface BulkKeeperDirectiveResult {
  name: string
  ok: boolean
  error?: string
}

export interface BulkKeeperDirectiveResponse {
  ok: boolean
  action: BulkKeeperDirectiveAction
  requested: number
  succeeded: number
  results: BulkKeeperDirectiveResult[]
}

/**
 * Apply pause/resume/wakeup to N keepers in one request.
 * Backend collapses the per-keeper cache invalidate into a single batch
 * invalidate at the end, so dashboard rebuild cost is O(1) instead of
 * O(N). Returns a per-keeper result array for granular UI feedback.
 */
export function bulkKeeperDirective(
  targets: BulkKeeperResumeTarget[],
  action: 'resume',
  opts?: KeeperControlOptions,
): Promise<BulkKeeperDirectiveResponse>
export function bulkKeeperDirective(
  names: string[],
  action: 'pause' | 'wakeup',
  opts?: KeeperControlOptions,
): Promise<BulkKeeperDirectiveResponse>
export async function bulkKeeperDirective(
  subjects: string[] | BulkKeeperResumeTarget[],
  action: BulkKeeperDirectiveAction,
  opts: KeeperControlOptions = {},
): Promise<BulkKeeperDirectiveResponse> {
  const names = subjects.map(subject => typeof subject === 'string' ? subject : subject.name)
  const fallbackError = `Failed to ${action} ${subjects.length} keeper(s)`
  const resumeTargets = action === 'resume' ? subjects as BulkKeeperResumeTarget[] : []
  const resumeIntents = action === 'resume'
    ? resumeTargets.map(target => ({
        name: target.name,
        intent: resumeIntent(target.name, target.operatorOperationId),
      }))
    : []
  const body = action === 'resume'
    ? {
        action,
        targets: resumeIntents.map(({ name, intent }) => ({
          name,
          operator_operation_id: intent.operatorOperationId,
        })),
      }
    : { names, action }
  try {
    const resp = await fetchControlPlane(
      '/api/v1/keepers_bulk/directive',
      {
        method: 'POST',
        headers: jsonHeaders(),
        body: JSON.stringify(body),
        signal: opts.signal,
      },
    )
    const payload = await safeJsonResponse<BulkKeeperDirectiveResponse>(
      resp,
      fallbackError,
    )
    if (isRecord(payload) && Array.isArray(payload.results)) {
      for (const result of payload.results) {
        if (!isRecord(result) || result.ok !== true || typeof result.name !== 'string') continue
        const committed = resumeIntents.find(({ name }) => name === result.name)
        if (committed) clearCommittedResumeIntent(committed.name, committed.intent)
      }
      return payload as unknown as BulkKeeperDirectiveResponse
    }
    return {
      ok: false,
      action,
      requested: names.length,
      succeeded: 0,
      results: names.map(name => ({ name, ok: false, error: fallbackError })),
    }
  } catch (err) {
    if (isAbortError(err)) throw err
    return {
      ok: false,
      action,
      requested: names.length,
      succeeded: 0,
      results: names.map(name => ({
        name,
        ok: false,
        error: err instanceof Error ? err.message : fallbackError,
      })),
    }
  }
}

// --- Keeper purge (permanent removal) ---

// The purge endpoint admits a keeper from its persisted metadata rather than
// from a live registry lane, so a keeper that has already stopped is a valid
// target. `masc_keeper_down` cannot reach those: it refuses a keeper whose
// metadata exists without a live lane.
export interface KeeperPurgeResponse {
  ok: true
  accepted: true
  target_kind: 'keeper'
  keeper_name: string
  operation_id: string
}

export function decodeKeeperPurgeResponse(value: unknown, requestedName: string): KeeperPurgeResponse {
  if (!isRecord(value) || value.ok !== true || value.accepted !== true
      || value.target_kind !== 'keeper' || value.keeper_name !== requestedName.trim()
      || typeof value.operation_id !== 'string' || value.operation_id.trim() === '') {
    throw new Error('키퍼 삭제 접수 응답의 대상 또는 작업 ID가 올바르지 않습니다')
  }
  return {
    ok: true, accepted: true, target_kind: 'keeper',
    keeper_name: value.keeper_name, operation_id: value.operation_id,
  }
}

// What the server's purge plan removes, in the order it removes it
// (Keeper_shutdown_types.dashboard_purge_artifact_plan). The confirmation UI
// shows this list, so it must stay in step with that plan.
export const KEEPER_PURGE_ARTIFACTS: readonly string[] = [
  '메트릭 저장소',
  '결정·피드백·상태 전이 로그와 회전 보관본',
  '런타임 디렉터리',
  'Memory OS 스냅샷과 저널',
  '격리 작업 디렉터리',
  '런타임 배정과 Keeper별 egress 설정',
  'TOML 설정',
  '대화 기록',
  '에이전트 파일과 인증 토큰',
]

export async function purgeKeeper(name: string): Promise<KeeperPurgeResponse> {
  const resp = await fetchControlPlane('/api/v1/dashboard/agents/purge', {
    method: 'POST',
    headers: jsonHeaders(),
    body: JSON.stringify({ agent_name: name }),
  })
  if (!resp.ok) {
    const payload = await safeJsonResponse<{ error?: string }>(
      resp,
      `${name} 제거 실패`,
    )
    throw new Error(
      typeof payload.error === 'string' && payload.error.trim() !== ''
        ? payload.error
        : `${name} 제거 실패 (HTTP ${resp.status})`,
    )
  }
  return decodeKeeperPurgeResponse(await resp.json(), name)
}

const purgePhaseLabels = {
  prepared: '종료 접수',
  joining_lanes: '실행 중인 레인 종료 대기',
  joined_idle: '레인 종료 확인',
  finalizing_tasks: '소유한 Task 정리 중',
  cleanup_ready: '파일 정리 준비',
  reconciliation_required: '진행 중이던 도구 실행 결과 확인 필요',
  finalized: '종료 처리됨 · 추가 정리 완료 확인 중',
  owner_absent: '실행 소유자 부재',
  operator_absence_acknowledged: '운영자가 소유자 부재 확인',
  blocked: '종료 작업 중단',
  superseded: '다른 운영 작업으로 대체됨',
  cleanup_required: '설정 정리 실패',
  artifacts_removed: '설정 파일 제거 대기',
  removed: '설정 삭제 및 정리 완료',
} as const

export interface KeeperPurgeStatus {
  kind: 'runtime_shutdown' | 'configuration_removal'
  source: { path: string; sha256: string } | null
  keeperName: string
  operationId: string
  completed: boolean
  canRetry: boolean
  phase: keyof typeof purgePhaseLabels
  description: string
}

export async function fetchKeeperPurgeStatus(name: string, operationId: string): Promise<KeeperPurgeStatus> {
  const query = new URLSearchParams({ keeper_name: name.trim(), operation_id: operationId })
  const response = await fetchControlPlane(`/api/v1/dashboard/keepers/purge-status?${query}`, {
    method: 'GET', headers: jsonHeaders(),
  })
  if (!response.ok) {
    throw new Error(`삭제 상태 확인 실패 (HTTP ${response.status}): ${await response.text()}`)
  }
  const result = decodeKeeperPurgeStatus(await response.json())
  if (result.keeperName !== name.trim() || result.operationId !== operationId) {
    throw new Error('삭제 상태 응답이 요청한 작업과 다릅니다')
  }
  return result
}

function decodeKeeperPurgeStatus(value: unknown): KeeperPurgeStatus {
  if (!isRecord(value) || !isRecord(value.operation)
    || !isRecord(value.operation.phase) || value.operation.phase.kind !== value.phase
    || typeof value.operation.keeper_name !== 'string' || !value.operation.keeper_name.trim()
    || typeof value.operation.operation_id !== 'string' || !value.operation.operation_id.trim()
    || typeof value.completed !== 'boolean'
    || typeof value.can_retry !== 'boolean'
    || typeof value.phase !== 'string'
    || !Object.prototype.hasOwnProperty.call(purgePhaseLabels, value.phase)
    || !(value.failure === null || typeof value.failure === 'string')
    || (value.completed && value.phase !== 'finalized')
    || (value.can_retry && (value.completed || value.phase !== 'finalized'))) {
    throw new Error('삭제 상태 응답의 작업 식별자 또는 상태가 올바르지 않습니다')
  }
  if (value.phase === 'cleanup_required' || value.phase === 'artifacts_removed' || value.phase === 'removed') {
    throw new Error('런타임 종료 기록에 설정 전용 삭제 상태가 들어 있습니다')
  }
  let completed = false
  let canRetry = false
  if (value.phase === 'finalized') {
    const evidence = value.operation.phase.evidence
    if (!isRecord(evidence) || !isRecord(evidence.completion)
      || evidence.completion.action !== 'dashboard_keeper_purged') {
      throw new Error('런타임 삭제 완료 영수증이 없습니다')
    }
    const kind = evidence.completion.kind
    if (kind !== 'delivered' && kind !== 'pending' && kind !== 'delivery_failed') {
      throw new Error('알 수 없는 삭제 정리 영수증 상태입니다')
    }
    completed = kind === 'delivered'
    canRetry = kind === 'pending' || kind === 'delivery_failed'
  }
  if (value.completed !== completed || value.can_retry !== canRetry) {
    throw new Error('삭제 표시 상태가 종료 원장과 모순됩니다')
  }
  const label = value.completed ? '삭제 및 정리 완료'
    : value.phase === 'finalized' && value.failure !== null ? '파일·설정 정리 실패'
    : purgePhaseLabels[value.phase as keyof typeof purgePhaseLabels]
  return { kind: 'runtime_shutdown', source: null, keeperName: value.operation.keeper_name, operationId: value.operation.operation_id,
    phase: value.phase as keyof typeof purgePhaseLabels,
    completed: value.completed, canRetry: value.can_retry,
    description: value.failure ? `${label}: ${value.failure}` : label }
}

export async function retryKeeperDeletion(name: string, operationId: string, kind: KeeperPurgeStatus['kind']): Promise<KeeperPurgeResponse> {
  const path = kind === 'configuration_removal'
    ? '/api/v1/dashboard/keepers/configuration-deletions/retry'
    : '/api/v1/dashboard/keepers/deletions/retry'
  const response = await fetchControlPlane(path, {
    method: 'POST', headers: jsonHeaders(),
    body: JSON.stringify({ keeper_name: name, operation_id: operationId }),
  })
  if (!response.ok) throw new Error(`삭제 정리 재시도 실패 (HTTP ${response.status}): ${await response.text()}`)
  const receipt = decodeKeeperPurgeResponse(await response.json(), name)
  if (receipt.operation_id !== operationId) throw new Error('재시도 응답의 삭제 작업 ID가 다릅니다')
  return receipt
}

export interface KeeperDeletionInventory {
  configurationErrors: string[]
  operations: KeeperPurgeStatus[]
  errors: { keeperName: string; operationId: string; error: string }[]
}

export async function fetchKeeperDeletions(): Promise<KeeperDeletionInventory> {
  const response = await fetchControlPlane('/api/v1/dashboard/keepers/deletions', {
    method: 'GET', headers: jsonHeaders(),
  })
  if (!response.ok) throw new Error(`삭제 기록 조회 실패 (HTTP ${response.status}): ${await response.text()}`)
  const value: unknown = await response.json()
  if (!isRecord(value) || !Array.isArray(value.operations) || !Array.isArray(value.errors)
    || !Array.isArray(value.configuration_removals) || !Array.isArray(value.configuration_errors)) {
    throw new Error('삭제 기록 응답 형식이 올바르지 않습니다')
  }
  const configurationRows: KeeperPurgeStatus[] = value.configuration_removals.map((row: unknown) => {
    if (!isRecord(row) || row.kind !== 'configuration_removal' || !isRecord(row.state)
      || typeof row.operation_id !== 'string' || !row.operation_id.trim()
      || typeof row.keeper_name !== 'string' || !row.keeper_name.trim()
      || typeof row.source_path !== 'string' || !row.source_path.trim()
      || typeof row.source_sha256 !== 'string' || !row.source_sha256.trim()
      || !(row.state.error === null || typeof row.state.error === 'string')) {
      throw new Error('설정 삭제 기록 형식이 올바르지 않습니다')
    }
    const phase = row.state.kind
    if (phase !== 'prepared' && phase !== 'cleanup_required' && phase !== 'artifacts_removed' && phase !== 'removed') {
      throw new Error('알 수 없는 설정 삭제 상태입니다')
    }
    if (((phase === 'removed' || phase === 'prepared') && row.state.error !== null)
      || (phase === 'cleanup_required' && (typeof row.state.error !== 'string' || !row.state.error.trim()))) {
      throw new Error('설정 삭제 상태와 오류 정보가 모순됩니다')
    }
    const label = phase === 'prepared' ? '설정 삭제 접수' : purgePhaseLabels[phase]
    return { kind: 'configuration_removal', source: { path: row.source_path, sha256: row.source_sha256 },
      keeperName: row.keeper_name, operationId: row.operation_id, phase,
      completed: phase === 'removed', canRetry: phase !== 'removed',
      description: row.state.error ? `${label}: ${row.state.error}` : label }
  })
  const configurationErrors = value.configuration_errors.map((error: unknown) => {
    if (typeof error !== 'string') throw new Error('설정 삭제 조회 오류 형식이 올바르지 않습니다')
    return error
  })
  const operations = [...value.operations.map(decodeKeeperPurgeStatus), ...configurationRows]
  const errors = value.errors.map((error: unknown) => {
    if (!isRecord(error) || typeof error.keeper_name !== 'string'
      || typeof error.operation_id !== 'string' || typeof error.error !== 'string') {
      throw new Error('삭제 기록 오류 정보가 올바르지 않습니다')
    }
    return { keeperName: error.keeper_name, operationId: error.operation_id, error: error.error }
  })
  return { operations, errors, configurationErrors }
}

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
  ownerGeneration: number
  operatorOperationId: string
}

const pendingResumeIntents = new Map<string, PendingResumeIntent>()

function createResumeOperationId(): string {
  return `dashboard-resume-${crypto.randomUUID()}`
}

function resumeIntent(
  name: string,
  ownerGeneration: number,
  explicitOperationId?: string,
): PendingResumeIntent {
  if (explicitOperationId) {
    return { ownerGeneration, operatorOperationId: explicitOperationId }
  }
  const pending = pendingResumeIntents.get(name)
  if (pending?.ownerGeneration === ownerGeneration) return pending
  const created = {
    ownerGeneration,
    operatorOperationId: createResumeOperationId(),
  }
  pendingResumeIntents.set(name, created)
  return created
}

function clearCommittedResumeIntent(name: string, intent: PendingResumeIntent): void {
  const pending = pendingResumeIntents.get(name)
  if (pending?.operatorOperationId === intent.operatorOperationId) {
    pendingResumeIntents.delete(name)
  }
}

function isOwnerGeneration(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
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
  source_kind: 'oas_current' | 'oas_history' | string
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

export interface KeeperCheckpointInventory {
  keeper: string
  trace_id: string
  session_dir: string
  current: KeeperCheckpointSummary | null
  history: KeeperCheckpointSummary[]
}

interface KeeperCheckpointDeleteResponse {
  ok: boolean
  action: 'delete_history' | string
  keeper: string
  deleted_snapshot_ids: string[]
  missing_snapshot_ids: string[]
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
  ownerGeneration: number | null | undefined,
  opts: KeeperResumeOptions = {},
): Promise<KeeperLifecycleResponse> {
  if (!isOwnerGeneration(ownerGeneration)) {
    return {
      ok: false,
      action: 'resume',
      name,
      error: `Cannot resume ${name}: current owner generation is unavailable`,
    }
  }
  const intent = resumeIntent(name, ownerGeneration, opts.operatorOperationId)
  const result = await safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    {
      action: 'resume',
      owner_nonce: intent.ownerGeneration,
      operator_operation_id: intent.operatorOperationId,
    },
    `Failed to resume ${name}`,
    opts,
  )
  if (result.ok || result.committed === true) clearCommittedResumeIntent(name, intent)
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
  ownerGeneration: number
  operatorOperationId?: string
}

export interface BulkKeeperDirectiveResult {
  name: string
  ok: boolean
  action?: KeeperLifecycleResponse['action']
  committed?: boolean
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
  const invalidResumeTarget = resumeTargets.find(
    target => typeof target.name !== 'string' || !isOwnerGeneration(target.ownerGeneration),
  )
  if (invalidResumeTarget) {
    const error = `Cannot resume ${invalidResumeTarget.name}: current owner generation is unavailable`
    return {
      ok: false,
      action,
      requested: subjects.length,
      succeeded: 0,
      results: names.map(name => ({ name, ok: false, error })),
    }
  }
  const resumeIntents = action === 'resume'
    ? resumeTargets.map(target => ({
        name: target.name,
        intent: resumeIntent(
          target.name,
          target.ownerGeneration,
          target.operatorOperationId,
        ),
      }))
    : []
  const body = action === 'resume'
    ? {
        action,
        targets: resumeIntents.map(({ name, intent }) => ({
          name,
          owner_nonce: intent.ownerGeneration,
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
      const intentsByName = new Map(
        resumeIntents.map(({ name, intent }) => [name, intent] as const),
      )
      let recoveredCommittedResume = false
      const results = await Promise.all(payload.results.map(async rawResult => {
        if (!isRecord(rawResult) || typeof rawResult.name !== 'string') {
          return rawResult as unknown as BulkKeeperDirectiveResult
        }
        const result = rawResult as unknown as BulkKeeperDirectiveResult
        const intent = intentsByName.get(result.name)
        if (intent && (result.ok || result.committed === true)) {
          clearCommittedResumeIntent(result.name, intent)
        }
        if (action === 'resume' && !result.ok && result.committed === true) {
          recoveredCommittedResume = true
          const boot = await bootKeeper(result.name, opts)
          return { ...result, ...boot, name: result.name, committed: true }
        }
        return result
      }))
      if (!recoveredCommittedResume) {
        return { ...(payload as unknown as BulkKeeperDirectiveResponse), results }
      }
      const succeeded = results.filter(result => result.ok).length
      return {
        ...(payload as unknown as BulkKeeperDirectiveResponse),
        ok: succeeded === names.length,
        succeeded,
        results,
      }
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

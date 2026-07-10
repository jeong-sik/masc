// MASC Dashboard — Keeper lifecycle (boot/shutdown/reset/clear/checkpoints/pause/resume/wake/bulk) (split from keeper.ts)

import { isRecord } from '../components/common/normalize'
import {
  fetchWithTimeout,
  jsonHeaders,
  DEFAULT_GET_TIMEOUT_MS,
  DEFAULT_POST_TIMEOUT_MS,
  KEEPER_LIFECYCLE_TIMEOUT_MS,
} from './core'

// --- Keeper lifecycle (boot / shutdown) ---

interface KeeperLifecycleResponse {
  ok: boolean
  action?: 'boot' | 'shutdown' | 'reset' | 'clear'
  name?: string
  detail?: unknown
  error?: string
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
    const resp = await fetchWithTimeout(url, {
      method: 'POST',
      headers: jsonHeaders(),
      ...init,
    }, KEEPER_LIFECYCLE_TIMEOUT_MS)
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
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

async function safeKeeperPostWithBody(
  url: string,
  body: Record<string, unknown>,
  fallbackError: string,
): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetchWithTimeout(url, {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify(body),
    }, DEFAULT_POST_TIMEOUT_MS)
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
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

export function bootKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/boot`,
    `Failed to boot ${name}`,
  )
}

export function shutdownKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/shutdown`,
    `Failed to shut down ${name}`,
  )
}

export function resetKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/reset`,
    `Failed to reset ${name}`,
  )
}

interface KeeperClearRequest {
  reason: string
  preserve_system_prompt?: boolean
}

export function clearKeeper(
  name: string,
  payload: KeeperClearRequest,
): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/clear`,
    `Failed to clear ${name}`,
    {
      body: JSON.stringify(payload),
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

export function pauseKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'pause' },
    `Failed to pause ${name}`,
  )
}

export function resumeKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'resume' },
    `Failed to resume ${name}`,
  )
}

export function wakeKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'wakeup' },
    `Failed to wake ${name}`,
  )
}

export type BulkKeeperDirectiveAction = 'pause' | 'resume' | 'wakeup'

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
export async function bulkKeeperDirective(
  names: string[],
  action: BulkKeeperDirectiveAction,
): Promise<BulkKeeperDirectiveResponse> {
  const fallbackError = `Failed to ${action} ${names.length} keeper(s)`
  try {
    const resp = await fetchWithTimeout(
      '/api/v1/keepers_bulk/directive',
      {
        method: 'POST',
        headers: jsonHeaders(),
        body: JSON.stringify({ names, action }),
      },
      DEFAULT_POST_TIMEOUT_MS,
    )
    const payload = await safeJsonResponse<BulkKeeperDirectiveResponse>(
      resp,
      fallbackError,
    )
    if (resp.ok && isRecord(payload) && payload.ok === true) {
      return payload
    }
    return {
      ok: false,
      action,
      requested: names.length,
      succeeded: 0,
      results: names.map(name => ({ name, ok: false, error: fallbackError })),
    }
  } catch (err) {
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

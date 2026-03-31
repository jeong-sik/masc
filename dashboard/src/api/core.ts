// MASC Dashboard — HTTP infrastructure, auth, and generic fetchers
// All fetch calls go through this module for consistent auth and typing

import type {
  OperatorActionRequest,
  OperatorActionResult,
  OperatorDigest,
  OperatorSnapshot,
} from '../types'
import { resolveDashboardActorName, sanitizeDashboardActorName } from '../lib/dashboard-actor'
import { resolveDashboardAuthToken } from '../lib/dashboard-auth'

// --- Auth ---
// Token bootstrap (URL -> sessionStorage -> strip) is handled by
// bootstrapDashboardAuthTokenFromUrl() called in main.ts.
// resolveDashboardAuthToken() only reads the scrubbed sessionStorage copy.

function getQueryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search)
}

export function currentDashboardActor(): string {
  return resolveDashboardActorName() || 'dashboard'
}

type HeaderOptions = {
  includeActor?: boolean
}

function authHeaders(options: HeaderOptions = {}): Record<string, string> {
  const headers: Record<string, string> = {}
  const token = resolveDashboardAuthToken()
  const agent = resolveDashboardActorName(window.location.search)
  if (token) headers['Authorization'] = `Bearer ${token}`
  if (options.includeActor !== false && agent) {
    headers['X-MASC-Agent'] = agent
  }
  return headers
}

function jsonHeaders(): Record<string, string> {
  return {
    ...authHeaders(),
    'Content-Type': 'application/json',
  }
}

import {
  DEFAULT_GET_TIMEOUT_MS,
  DEFAULT_POST_TIMEOUT_MS,
  KEEPER_MESSAGE_TIMEOUT_MS,
  SOCIAL_SWEEP_TIMEOUT_MS,
} from '../config/constants'

// Re-export so existing consumers keep working
export {
  DEFAULT_GET_TIMEOUT_MS,
  DEFAULT_POST_TIMEOUT_MS,
  DEFAULT_MCP_TIMEOUT_MS,
  ROOM_TRUTH_GET_TIMEOUT_MS,
} from '../config/constants'
const RETRYABLE_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504])

class ApiRequestError extends Error {
  method: string
  path: string
  status?: number
  statusText?: string
  timeout: boolean

  constructor(opts: {
    method: string
    path: string
    status?: number
    statusText?: string
    timeout?: boolean
    timeoutMs?: number
  }) {
    const method = opts.method.toUpperCase()
    const timeout = opts.timeout === true
    const message = timeout
      ? `${method} ${opts.path}: timeout after ${opts.timeoutMs ?? 0}ms`
      : `${method} ${opts.path}: ${opts.status ?? 'unknown'} ${opts.statusText ?? ''}`.trim()
    super(message)
    this.name = 'ApiRequestError'
    this.method = method
    this.path = opts.path
    this.status = opts.status
    this.statusText = opts.statusText
    this.timeout = timeout
  }
}

export async function fetchWithTimeout(path: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(path, {
      ...init,
      signal: controller.signal,
    })
  } catch (err) {
    if (err instanceof Error && err.name === 'AbortError') {
      const method = typeof init.method === 'string' ? init.method.toUpperCase() : 'GET'
      throw new ApiRequestError({
        method,
        path,
        timeout: true,
        timeoutMs,
      })
    }
    throw err
  } finally {
    clearTimeout(timer)
  }
}

export function defaultBoardVoter(): string {
  const params = getQueryParams()
  return sanitizeDashboardActorName(params.get('agent'))
    || sanitizeDashboardActorName(params.get('agent_name'))
    || 'dashboard-user'
}

// --- Generic fetcher ---

export type GetOptions = {
  timeoutMs?: number
  includeActorHeader?: boolean
}

export async function get<T>(path: string, opts: GetOptions = {}): Promise<T> {
  const res = await fetchWithTimeout(
    path,
    { headers: authHeaders({ includeActor: opts.includeActorHeader }) },
    opts.timeoutMs ?? DEFAULT_GET_TIMEOUT_MS,
  )
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'GET',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.json() as Promise<T>
}

export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function parseStatusFromMessage(message: string): number | null {
  const match = message.match(/\b(\d{3})\b/)
  if (!match) return null
  const statusToken = match[1]
  if (!statusToken) return null
  const status = Number.parseInt(statusToken, 10)
  return Number.isFinite(status) ? status : null
}

function isRetryableError(err: unknown): boolean {
  if (err instanceof ApiRequestError) {
    return err.timeout || (typeof err.status === 'number' && RETRYABLE_STATUS_CODES.has(err.status))
  }

  if (!(err instanceof Error)) return false
  if (/timeout after \d+ms/i.test(err.message)) return true

  // Network-level failures (server unreachable, connection reset, DNS failure).
  // Browser fetch() throws TypeError on these — they are transient.
  if (err instanceof TypeError && /failed to fetch|networkerror|load failed/i.test(err.message)) {
    return true
  }

  const parsedStatus = parseStatusFromMessage(err.message)
  return parsedStatus !== null && RETRYABLE_STATUS_CODES.has(parsedStatus)
}

export async function withRetries<T>(
  operation: string,
  run: () => Promise<T>,
  retries = 2,
): Promise<T> {
  let attempt = 0

  while (true) {
    try {
      return await run()
    } catch (err) {
      if (!isRetryableError(err) || attempt >= retries) throw err
      const delayMs = 250 * (attempt + 1)
      console.warn(`[dashboard/api] ${operation} failed (attempt ${attempt + 1}), retrying in ${delayMs}ms`, err)
      await sleep(delayMs)
      attempt += 1
    }
  }
}

export async function post<T>(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<T> {
  const res = await fetchWithTimeout(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  }, timeoutMs)
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'POST',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.json() as Promise<T>
}

export async function patch<T>(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<T> {
  // Backend uses POST with PATCH semantics (OCaml server only routes POST)
  const res = await fetchWithTimeout(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  }, timeoutMs)
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'PATCH',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.json() as Promise<T>
}

export async function postRaw(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<string> {
  const res = await fetchWithTimeout(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  }, timeoutMs)
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'POST',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.text()
}

// --- Operator ---

function operatorActionTimeoutMs(body: OperatorActionRequest): number {
  switch (body.action_type) {
    case 'keeper_message':
    case 'keeper_recover':
      return KEEPER_MESSAGE_TIMEOUT_MS
    case 'social_sweep':
      return SOCIAL_SWEEP_TIMEOUT_MS
    default:
      return DEFAULT_POST_TIMEOUT_MS
  }
}

export function runOperatorAction(body: OperatorActionRequest): Promise<OperatorActionResult> {
  return post('/api/v1/operator/action', body, undefined, operatorActionTimeoutMs(body))
}

export function confirmOperatorAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
): Promise<OperatorActionResult> {
  return post('/api/v1/operator/confirm', {
    actor,
    confirm_token: confirmToken,
    decision,
  })
}

export function fetchOperatorSnapshot(): Promise<OperatorSnapshot> {
  return get('/api/v1/operator', { includeActorHeader: false })
}

export function fetchOperatorDigest(options: {
  targetType?: 'room' | 'team_session'
  targetId?: string
  includeWorkers?: boolean
} = {}): Promise<OperatorDigest> {
  const params = new URLSearchParams()
  if (options.targetType) params.set('target_type', options.targetType)
  if (options.targetId) params.set('target_id', options.targetId)
  if (options.includeWorkers != null) params.set('include_workers', options.includeWorkers ? 'true' : 'false')
  const query = params.toString()
  return get(`/api/v1/operator/digest${query ? `?${query}` : ''}`, {
    includeActorHeader: false,
  })
}

// MASC Dashboard — HTTP infrastructure, auth, and generic fetchers
// All fetch calls go through this module for consistent auth and typing

import type {
  OperatorActionRequest,
  OperatorActionResult,
  OperatorDigest,
  OperatorSnapshot,
} from '../types'
import { parseOperatorActionResult } from './schemas/operator-action'
import { resolveDashboardActorName, sanitizeDashboardActorName } from '../lib/dashboard-actor'

// --- Auth ---
// Token is read from ?token= on first load, moved to sessionStorage,
// then stripped from the URL to avoid exposure in history/logs.

function getQueryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search)
}

const TOKEN_STORAGE_KEY = 'masc_bearer_token'

function initTokenFromUrl(): void {
  const params = new URLSearchParams(window.location.search)
  const urlToken = params.get('token')
  if (urlToken) {
    sessionStorage.setItem(TOKEN_STORAGE_KEY, urlToken)
    params.delete('token')
    const cleaned = params.toString()
    const newUrl = window.location.pathname + (cleaned ? `?${cleaned}` : '') + window.location.hash
    history.replaceState(null, '', newUrl)
  }
}

initTokenFromUrl()

export function getStoredToken(): string | null {
  return sessionStorage.getItem(TOKEN_STORAGE_KEY)
}

export function setStoredToken(token: string): void {
  sessionStorage.setItem(TOKEN_STORAGE_KEY, token)
}

export function clearStoredToken(): void {
  sessionStorage.removeItem(TOKEN_STORAGE_KEY)
}

export function isRemoteAccess(): boolean {
  const host = window.location.hostname
  return host !== 'localhost' && host !== '127.0.0.1' && host !== '::1'
}

export function currentDashboardActor(): string {
  return resolveDashboardActorName() || 'dashboard'
}

type HeaderOptions = {
  includeActor?: boolean
}

export function authHeaders(options: HeaderOptions = {}): Record<string, string> {
  const headers: Record<string, string> = {}
  const token = getStoredToken()
  const agent = resolveDashboardActorName(window.location.search)
  if (token) headers['Authorization'] = `Bearer ${token}`
  if (options.includeActor !== false && agent) {
    headers['X-MASC-Agent'] = agent
  }
  return headers
}

export function jsonHeaders(): Record<string, string> {
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
  NAMESPACE_TRUTH_GET_TIMEOUT_MS,
} from '../config/constants'
const RETRYABLE_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504])

export class ApiRequestError extends Error {
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

export interface ApiErrorSummary {
  message: string
  status: number | null
  path: string | null
  timeout: boolean
}

export function extractApiError(err: unknown, fallbackMessage: string): ApiErrorSummary {
  if (err instanceof ApiRequestError) {
    return {
      message: err.message,
      status: err.status ?? null,
      path: err.path,
      timeout: err.timeout,
    }
  }
  if (err instanceof Error) {
    return { message: err.message, status: null, path: null, timeout: false }
  }
  return { message: fallbackMessage, status: null, path: null, timeout: false }
}

export async function fetchWithTimeout(path: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController()
  const upstreamSignal = init.signal
  const abortFromUpstream = () => controller.abort()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  if (upstreamSignal) {
    if (upstreamSignal.aborted) {
      controller.abort()
    } else {
      upstreamSignal.addEventListener('abort', abortFromUpstream, { once: true })
    }
  }

  try {
    return await fetch(path, {
      ...init,
      signal: controller.signal,
    })
  } catch (err) {
    if (err instanceof Error && err.name === 'AbortError') {
      if (upstreamSignal?.aborted) {
        throw err
      }
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
    upstreamSignal?.removeEventListener('abort', abortFromUpstream)
  }
}

const DASHBOARD_BOOTSTRAP_WARM_PATHS = new Set([
  '/api/v1/dashboard/shell',
  '/api/v1/dashboard/namespace-truth',
  '/api/v1/dashboard/room-truth',
  '/api/v1/dashboard/execution',
  '/api/v1/dashboard/planning',
  '/api/v1/dashboard/mission',
])

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isNotInitializedEnvelope(raw: unknown): boolean {
  if (!isRecord(raw)) return false
  return typeof raw.error === 'string' && raw.error.trim().toLowerCase() === 'not initialized'
}

function bootstrapStatusEnvelope(generatedAt: string): Record<string, unknown> {
  return {
    project: 'initializing',
    generated_at: generatedAt,
  }
}

function bootstrapInitializingPayload(path: string): unknown | null {
  const generatedAt = new Date().toISOString()
  switch (path) {
    case '/api/v1/dashboard/shell':
      return {
        generated_at: generatedAt,
        status: bootstrapStatusEnvelope(generatedAt),
        counts: { agents: 0, tasks: 0, keepers: 0 },
        providers: {},
        meta_cognition: null,
        auth: null,
        config_resolution: null,
        runtime_resolution: null,
      }
    case '/api/v1/dashboard/namespace-truth':
    case '/api/v1/dashboard/room-truth':
      return {
        status: 'initializing',
        generated_at: generatedAt,
        message: 'Dashboard bootstrap is still warming up.',
      }
    case '/api/v1/dashboard/execution':
      return {
        generated_at: generatedAt,
        status: bootstrapStatusEnvelope(generatedAt),
        summary: {},
        execution_queue: [],
        operation_briefs: [],
        worker_support_briefs: [],
        continuity_briefs: [],
        offline_worker_briefs: [],
        agents: [],
        tasks: [],
        messages: [],
        keepers: [],
      }
    case '/api/v1/dashboard/planning':
      return {
        generated_at: generatedAt,
        goals: [],
        rollup: {},
        task_backlog: {
          todo: 0,
          claimed: 0,
          in_progress: 0,
          done: 0,
          cancelled: 0,
        },
      }
    case '/api/v1/dashboard/mission':
      return {
        generated_at: generatedAt,
        summary: {
          room_health: 'initializing',
        },
        incidents: [],
        recommended_actions: [],
        command_focus: {},
        operator_targets: { keepers: [], pending_confirms: [], available_actions: [] },
        attention_queue: [],
        sessions: [],
        agent_briefs: [],
        keeper_briefs: [],
        internal_signals: [],
      }
    default:
      return null
  }
}

async function bootstrapWarmPayload(path: string, res: Response): Promise<unknown | null> {
  if (!DASHBOARD_BOOTSTRAP_WARM_PATHS.has(path)) return null
  if (res.status < 500) return null
  let rawText = ''
  try {
    rawText = await res.text()
  } catch {
    return null
  }
  if (rawText.trim() === '') return null
  try {
    const parsed = JSON.parse(rawText) as unknown
    if (!isNotInitializedEnvelope(parsed)) return null
    return bootstrapInitializingPayload(path)
  } catch {
    return null
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
  signal?: AbortSignal
}

export async function get<T>(path: string, opts: GetOptions = {}): Promise<T> {
  const res = await fetchWithTimeout(
    path,
    {
      headers: authHeaders({ includeActor: opts.includeActorHeader }),
      signal: opts.signal,
    },
    opts.timeoutMs ?? DEFAULT_GET_TIMEOUT_MS,
  )
  if (!res.ok) {
    const warmPayload = await bootstrapWarmPayload(path, res)
    if (warmPayload !== null) {
      return warmPayload as T
    }
    throw new ApiRequestError({
      method: 'GET',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  const data = await res.json()
  // Server may return 200 OK with {"error":"not initialized"} during startup
  if (DASHBOARD_BOOTSTRAP_WARM_PATHS.has(path) && isNotInitializedEnvelope(data)) {
    const payload = bootstrapInitializingPayload(path)
    if (payload !== null) return payload as T
  }
  return data as T
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

export async function runOperatorAction(body: OperatorActionRequest): Promise<OperatorActionResult> {
  const raw = await post<unknown>(
    '/api/v1/operator/action',
    body,
    undefined,
    operatorActionTimeoutMs(body),
  )
  return parseOperatorActionResult(raw)
}

export async function confirmOperatorAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
): Promise<OperatorActionResult> {
  const raw = await post<unknown>('/api/v1/operator/confirm', {
    actor,
    confirm_token: confirmToken,
    decision,
  })
  return parseOperatorActionResult(raw)
}

export function fetchOperatorSnapshot(): Promise<OperatorSnapshot> {
  return get('/api/v1/operator', { includeActorHeader: false })
}

export function fetchOperatorDigest(options: {
  targetType?: 'namespace' | 'room'
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

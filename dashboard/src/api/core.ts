// MASC Dashboard — HTTP infrastructure, auth, and generic fetchers
// All fetch calls go through this module for consistent auth and typing

import type {
  OperatorActionRequest,
  OperatorActionResult,
  OperatorDigest,
  OperatorSnapshot,
} from '../types'
import { sanitizeDashboardActorName } from '../lib/dashboard-actor'
import { isAbortError } from '../lib/async-state'
import {
  currentDashboardActorName,
  setCanonicalDashboardActor,
} from '../lib/dashboard-session-actor'

// --- Auth ---
// Bearer credentials are never accepted from the URL. Strip a rejected legacy
// token parameter from the current history entry so it cannot propagate through
// later navigation or referrers; authentication remains header-only.

function getQueryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search)
}

const TOKEN_STORAGE_KEY = 'masc_bearer_token'
const TOKEN_META_STORAGE_KEY = 'masc_bearer_token_meta'

type StoredTokenSource = 'dev' | 'manual'

const STORED_TOKEN_SOURCES = ['dev', 'manual'] as const

const DEFAULT_STORED_TOKEN_SOURCE: StoredTokenSource = 'manual'

export interface StoredTokenMeta {
  source: StoredTokenSource
  actor?: string | null
  scope?: string | null
}

export interface StoredTokenChange {
  token: string | null
  meta: StoredTokenMeta | null
}

type StoredTokenChangeListener = (change: StoredTokenChange) => void

const storedTokenChangeListeners = new Set<StoredTokenChangeListener>()

function notifyStoredTokenChange(change: StoredTokenChange): void {
  for (const listener of storedTokenChangeListeners) {
    try {
      listener(change)
    } catch (err) {
      console.warn('[dashboard-auth] token change listener failed', err)
    }
  }
}

export function subscribeStoredTokenChanges(
  listener: StoredTokenChangeListener,
): () => void {
  storedTokenChangeListeners.add(listener)
  return () => {
    storedTokenChangeListeners.delete(listener)
  }
}

function normalizeStoredTokenMeta(value: unknown): StoredTokenMeta | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const record = value as Record<string, unknown>
  const source = typeof record.source === 'string' ? record.source : null
  if (source === null || !(STORED_TOKEN_SOURCES as readonly string[]).includes(source)) return null
  const actor = sanitizeDashboardActorName(
    typeof record.actor === 'string' ? record.actor : null,
  )
  const scope =
    typeof record.scope === 'string' && record.scope.trim() !== ''
      ? record.scope.trim()
      : null
  return { source: source as StoredTokenSource, actor, scope }
}

function storedTokenMetaEquals(
  left: StoredTokenMeta | null,
  right: StoredTokenMeta | null,
): boolean {
  if (left === null || right === null) return left === right
  return left.source === right.source
    && (left.actor ?? null) === (right.actor ?? null)
    && (left.scope ?? null) === (right.scope ?? null)
}

function stripRejectedTokenQueryParam(): void {
  const params = new URLSearchParams(window.location.search)
  if (!params.has('token')) return
  params.delete('token')
  const cleaned = params.toString()
  const newUrl = window.location.pathname + (cleaned ? `?${cleaned}` : '') + window.location.hash
  history.replaceState(null, '', newUrl)
}

stripRejectedTokenQueryParam()

export function getStoredToken(): string | null {
  try {
    const token = sessionStorage.getItem(TOKEN_STORAGE_KEY)
    return typeof token === 'string' && token.trim() !== '' ? token : null
  } catch {
    return null
  }
}

export function dashboardBearerToken(): string | null {
  return getStoredToken()
}

/** Build the WebSocket subprotocol list without putting the bearer in a URL.
 * The token is hex-encoded into a dedicated protocol member and is emitted
 * only for the current origin; the server echoes only the application
 * protocol, never the credential member. */
export function websocketProtocolsWithDashboardBearer(
  rawUrl: string,
  applicationProtocol: string,
): string[] {
  const token = dashboardBearerToken()
  if (!token) return [applicationProtocol]
  if (typeof window === 'undefined') return [applicationProtocol]
  const base = window.location.href
  const url = new URL(rawUrl, base)
  const websocketProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  if (url.protocol !== websocketProtocol || url.host !== window.location.host) {
    return [applicationProtocol]
  }
  const bytes = new TextEncoder().encode(token)
  const tokenHex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
  return [applicationProtocol, `masc.bearer.hex.${tokenHex}`]
}

export function getStoredTokenMeta(): StoredTokenMeta | null {
  try {
    const raw = sessionStorage.getItem(TOKEN_META_STORAGE_KEY)
    if (!raw) return null
    return normalizeStoredTokenMeta(JSON.parse(raw))
  } catch {
    return null
  }
}

export function setStoredToken(
  token: string,
  meta: Partial<StoredTokenMeta> & { source?: StoredTokenSource } = {},
): void {
  const normalizedToken = token.trim()
  if (!normalizedToken) {
    clearStoredToken()
    return
  }
  const previousToken = getStoredToken()
  const previousMeta = getStoredTokenMeta()
  const nextMeta = normalizeStoredTokenMeta({
    source: meta.source ?? DEFAULT_STORED_TOKEN_SOURCE,
    actor: meta.actor ?? null,
    scope: meta.scope ?? null,
  })
  sessionStorage.setItem(TOKEN_STORAGE_KEY, normalizedToken)
  if (nextMeta) {
    sessionStorage.setItem(TOKEN_META_STORAGE_KEY, JSON.stringify(nextMeta))
  } else {
    sessionStorage.removeItem(TOKEN_META_STORAGE_KEY)
  }
  setCanonicalDashboardActor(null)
  if (previousToken !== normalizedToken || !storedTokenMetaEquals(previousMeta, nextMeta)) {
    notifyStoredTokenChange({
      token: normalizedToken,
      meta: nextMeta,
    })
  }
}

export function clearStoredToken(): void {
  const previousToken = getStoredToken()
  const previousMeta = getStoredTokenMeta()
  sessionStorage.removeItem(TOKEN_STORAGE_KEY)
  sessionStorage.removeItem(TOKEN_META_STORAGE_KEY)
  setCanonicalDashboardActor(null)
  if (previousToken !== null || previousMeta !== null) {
    notifyStoredTokenChange({
      token: null,
      meta: null,
    })
  }
}

export function isRemoteAccess(): boolean {
  const host = window.location.hostname
  return host !== 'localhost' && host !== '127.0.0.1' && host !== '::1'
}

export function currentDashboardActor(): string {
  const meta = getStoredTokenMeta()
  const managedActor = meta?.source === 'dev'
    ? sanitizeDashboardActorName(meta.actor)
    : null
  if (managedActor) return managedActor
  return currentDashboardActorName()
}

type HeaderOptions = {
  includeActor?: boolean
  actorName?: string | null
}

export function authHeaders(options: HeaderOptions = {}): Record<string, string> {
  const headers: Record<string, string> = {}
  const token = dashboardBearerToken()
  const agent = options.actorName !== undefined
    ? sanitizeDashboardActorName(options.actorName)
    : currentDashboardActor()
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
  KEEPER_LIFECYCLE_TIMEOUT_MS,
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
  detail?: string
  errorCode?: string

  constructor(opts: {
    method: string
    path: string
    status?: number
    statusText?: string
    timeout?: boolean
    timeoutMs?: number
    detail?: string
    errorCode?: string
  }) {
    const method = opts.method.toUpperCase()
    const timeout = opts.timeout === true
    const detail = opts.detail?.trim()
    const message = timeout
      ? `${method} ${opts.path}: timeout after ${opts.timeoutMs ?? 0}ms`
      : detail
        ? `${method} ${opts.path}: ${detail}`
        : `${method} ${opts.path}: ${opts.status ?? 'unknown'} ${opts.statusText ?? ''}`.trim()
    super(message)
    this.name = 'ApiRequestError'
    this.method = method
    this.path = opts.path
    this.status = opts.status
    this.statusText = opts.statusText
    this.timeout = timeout
    this.detail = detail
    this.errorCode = opts.errorCode?.trim() || undefined
  }
}

interface ApiErrorSummary {
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
      cache: init.cache ?? 'no-store',
      signal: controller.signal,
    })
  } catch (err) {
    if (isAbortError(err)) {
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
  '/api/v1/dashboard/project-snapshot',
  '/api/v1/dashboard/namespace-truth',
  '/api/v1/dashboard/workspace-truth',
  '/api/v1/dashboard/execution',
  '/api/v1/dashboard/planning',
  '/api/v1/dashboard/briefing',
])

import { isRecord } from '../lib/type-guards'

interface ErrorResponseInfo {
  detail?: string
  errorCode?: string
}

async function errorResponseInfoFromResponse(res: Response): Promise<ErrorResponseInfo> {
  let rawText = ''
  try {
    rawText = (await res.text()).trim()
  } catch {
    return {}
  }
  if (!rawText) return {}
  try {
    const parsed = JSON.parse(rawText) as unknown
    if (isRecord(parsed)) {
      const errorCode =
        (typeof parsed.error === 'string' ? parsed.error.trim() : '')
        || (typeof parsed.status === 'string' ? parsed.status.trim() : '')
      const message = typeof parsed.message === 'string' ? parsed.message.trim() : ''
      if (message || errorCode) {
        return {
          detail: message || errorCode || undefined,
          errorCode: errorCode || undefined,
        }
      }
    }
  } catch {
    // Fall through to plain-text body.
  }
  return { detail: rawText }
}

export async function apiRequestErrorFromResponse(
  method: string,
  path: string,
  res: Response,
): Promise<ApiRequestError> {
  const info = await errorResponseInfoFromResponse(res)
  return new ApiRequestError({
    method,
    path,
    status: res.status,
    statusText: res.statusText,
    detail: info.detail,
    errorCode: info.errorCode,
  })
}

async function parseJsonResponse<T>(
  method: string,
  path: string,
  res: Response,
): Promise<T> {
  let rawText = ''
  try {
    rawText = await res.text()
  } catch {
    throw new ApiRequestError({
      method,
      path,
      status: res.status,
      statusText: res.statusText,
      detail: 'failed to read response body',
    })
  }

  if (rawText.trim() === '') {
    throw new ApiRequestError({
      method,
      path,
      status: res.status,
      statusText: res.statusText,
      detail: 'empty JSON response',
    })
  }

  try {
    return JSON.parse(rawText) as T
  } catch {
    throw new ApiRequestError({
      method,
      path,
      status: res.status,
      statusText: res.statusText,
      detail: 'invalid JSON response',
    })
  }
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
        auth: null,
        config_resolution: null,
        runtime_resolution: null,
      }
    case '/api/v1/dashboard/project-snapshot':
    case '/api/v1/dashboard/namespace-truth':
    case '/api/v1/dashboard/workspace-truth':
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
        workspace_fsm: {
          schema_version: 1,
          mode: 'advisory',
          summary: {
            products: 0,
            violations: 0,
            evidence: 0,
            severity_counts: { info: 0, warn: 0, error: 0 },
          },
          products: [],
          evidence: [],
          violations: [],
        },
      }
    case '/api/v1/dashboard/briefing':
      return {
        generated_at: generatedAt,
        summary: {
          workspace_health: 'initializing',
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

/**
 * Minimal request contract: the caller may pass an AbortSignal to cancel
 * the underlying fetch. Several api/* modules (dashboard, dashboard-hot,
 * transport-health) had defined this byte-for-byte locally; lifting it
 * here makes the abort contract single-sourced and lets callers compose
 * extensions like `AbortableRequestOptions & { light?: boolean }` against
 * a stable base.
 */
export type AbortableRequestOptions = {
  signal?: AbortSignal
}

export type GetOptions = AbortableRequestOptions & {
  timeoutMs?: number
  includeActorHeader?: boolean
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
    const warmPayload = await bootstrapWarmPayload(path, res.clone())
    if (warmPayload !== null) {
      return warmPayload as T
    }
    throw await apiRequestErrorFromResponse('GET', path, res)
  }
  const data = await parseJsonResponse<T>('GET', path, res)
  // Server may return 200 OK with {"error":"not initialized"} during startup
  if (DASHBOARD_BOOTSTRAP_WARM_PATHS.has(path) && isNotInitializedEnvelope(data)) {
    const payload = bootstrapInitializingPayload(path)
    if (payload !== null) return payload as T
  }
  return data
}

// Same wire shape as [get<T>] but exposes selected response headers
// alongside the parsed body. Use when a route returns metadata via
// header (e.g. [X-Workspace-Source]) so callers can read it without
// parsing the JSON body or breaking the existing return type.
//
// On bootstrap-warm fallback the returned [headers] is empty: warm
// payloads are synthesized locally and have no upstream response.
export async function getWithResponse<T>(
  path: string,
  opts: GetOptions = {},
): Promise<{ readonly data: T; readonly headers: Headers }> {
  const res = await fetchWithTimeout(
    path,
    {
      headers: authHeaders({ includeActor: opts.includeActorHeader }),
      signal: opts.signal,
    },
    opts.timeoutMs ?? DEFAULT_GET_TIMEOUT_MS,
  )
  if (!res.ok) {
    const warmPayload = await bootstrapWarmPayload(path, res.clone())
    if (warmPayload !== null) {
      return { data: warmPayload as T, headers: new Headers() }
    }
    throw await apiRequestErrorFromResponse('GET', path, res)
  }
  const data = await parseJsonResponse<T>('GET', path, res)
  if (DASHBOARD_BOOTSTRAP_WARM_PATHS.has(path) && isNotInitializedEnvelope(data)) {
    const payload = bootstrapInitializingPayload(path)
    if (payload !== null) return { data: payload as T, headers: new Headers() }
  }
  return { data, headers: res.headers }
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
    if (err.errorCode === 'computation_timeout' || err.errorCode === 'timeout') {
      return false
    }
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
    throw await apiRequestErrorFromResponse('POST', path, res)
  }
  return parseJsonResponse<T>('POST', path, res)
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
    throw await apiRequestErrorFromResponse('PATCH', path, res)
  }
  return parseJsonResponse<T>('PATCH', path, res)
}

export async function del<T>(
  path: string,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<T> {
  const res = await fetchWithTimeout(path, {
    method: 'DELETE',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
  }, timeoutMs)
  if (!res.ok) {
    throw await apiRequestErrorFromResponse('DELETE', path, res)
  }
  return parseJsonResponse<T>('DELETE', path, res)
}

export async function put<T>(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<T> {
  const res = await fetchWithTimeout(path, {
    method: 'PUT',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  }, timeoutMs)
  if (!res.ok) {
    throw await apiRequestErrorFromResponse('PUT', path, res)
  }
  return parseJsonResponse<T>('PUT', path, res)
}

// --- Operator ---

const OPERATOR_ACTION_TIMEOUT_MS: Record<string, number> = {
  keeper_message: KEEPER_MESSAGE_TIMEOUT_MS,
  keeper_recover: KEEPER_MESSAGE_TIMEOUT_MS,
  social_sweep: SOCIAL_SWEEP_TIMEOUT_MS,
}

function operatorActionTimeoutMs(body: OperatorActionRequest): number {
  return OPERATOR_ACTION_TIMEOUT_MS[body.action_type] ?? DEFAULT_POST_TIMEOUT_MS
}

export async function runOperatorAction(body: OperatorActionRequest): Promise<OperatorActionResult> {
  const raw = await post<unknown>(
    '/api/v1/operator/action',
    body,
    authHeaders({ actorName: body.actor }),
    operatorActionTimeoutMs(body),
  )
  const { parseOperatorActionResult } = await import('./schemas/operator-action')
  return parseOperatorActionResult(raw)
}

export async function confirmOperatorAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
): Promise<OperatorActionResult> {
  const raw = await post<unknown>(
    '/api/v1/operator/confirm',
    {
      actor,
      confirm_token: confirmToken,
      decision,
    },
    authHeaders({ actorName: actor }),
  )
  const { parseOperatorActionResult } = await import('./schemas/operator-action')
  return parseOperatorActionResult(raw)
}

export function fetchOperatorSnapshot(): Promise<OperatorSnapshot> {
  return get('/api/v1/operator', { includeActorHeader: false })
}

export function fetchOperatorDigest(options: {
  targetType?: 'namespace' | 'workspace'
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

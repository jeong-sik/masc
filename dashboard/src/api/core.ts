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
  currentCanonicalDashboardActor,
  currentDashboardActorName,
  setCanonicalDashboardActor,
} from '../lib/dashboard-session-actor'

// --- Auth ---
// Token is read from ?token= on first load, moved to sessionStorage,
// then stripped from the URL to avoid exposure in history/logs.

function getQueryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search)
}

const TOKEN_STORAGE_KEY = 'masc_bearer_token'
const TOKEN_META_STORAGE_KEY = 'masc_bearer_token_meta'

export type StoredTokenMeta =
  | { source: 'dev'; actor: 'dashboard'; role: 'admin' }
  | { source: 'manual' }
  | { source: 'url' }

export interface StoredTokenChange {
  token: string | null
  meta: StoredTokenMeta | null
}

type StoredTokenChangeListener = (change: StoredTokenChange) => void

const storedTokenChangeListeners = new Set<StoredTokenChangeListener>()
let storedTokenRevision = 0

function notifyStoredTokenChange(change: StoredTokenChange): void {
  storedTokenRevision += 1
  for (const listener of storedTokenChangeListeners) {
    try {
      listener(change)
    } catch (err) {
      console.warn('[dashboard-auth] token change listener failed', err)
    }
  }
}

export function currentStoredTokenRevision(): number {
  return storedTokenRevision
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
  if (record.source === 'manual') return { source: 'manual' }
  if (record.source === 'url') return { source: 'url' }
  if (
    record.source === 'dev'
    && record.actor === 'dashboard'
    && record.role === 'admin'
  ) {
    return { source: 'dev', actor: 'dashboard', role: 'admin' }
  }
  // A stored 'worker' dev meta from an older build parses as null, which
  // shouldRefreshDevToken treats as "re-bootstrap" — the migration is a
  // single silent re-fetch.
  return null
}

function storedTokenMetaEquals(
  left: StoredTokenMeta | null,
  right: StoredTokenMeta | null,
): boolean {
  if (left === null || right === null) return left === right
  if (left.source !== right.source) return false
  if (left.source !== 'dev' || right.source !== 'dev') return true
  return left.actor === right.actor && left.role === right.role
}

function initTokenFromUrl(): void {
  const params = new URLSearchParams(window.location.search)
  const urlToken = params.get('token')
  if (urlToken) {
    setStoredToken(urlToken, { source: 'url' })
    params.delete('token')
    const cleaned = params.toString()
    const newUrl = window.location.pathname + (cleaned ? `?${cleaned}` : '') + window.location.hash
    history.replaceState(null, '', newUrl)
  }
}

initTokenFromUrl()

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
  meta: StoredTokenMeta = { source: 'manual' },
): void {
  const normalizedToken = token.trim()
  if (!normalizedToken) {
    clearStoredToken()
    return
  }
  const previousToken = getStoredToken()
  const previousMeta = getStoredTokenMeta()
  const nextMeta = normalizeStoredTokenMeta(meta)
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
    ? meta.actor
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
  const tokenMeta = getStoredTokenMeta()
  const resolvedImplicitActor = token && tokenMeta?.source !== 'dev'
    ? currentCanonicalDashboardActor()
    : currentDashboardActor()
  const agent = options.actorName !== undefined
    ? sanitizeDashboardActorName(options.actorName)
    : resolvedImplicitActor
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
} from '../config/constants'

// Re-export so existing consumers keep working
export {
  DEFAULT_GET_TIMEOUT_MS,
  DEFAULT_POST_TIMEOUT_MS,
  DEFAULT_MCP_TIMEOUT_MS,
  NAMESPACE_TRUTH_GET_TIMEOUT_MS,
} from '../config/constants'

export class ApiRequestError extends Error {
  method: string
  path: string
  status?: number
  statusText?: string
  timeout: boolean
  detail?: string
  errorCode?: string
  authErrorCode?: string
  responseData?: unknown
  configApplied?: boolean
  configApplicationState?: 'indeterminate'
  runtimeSync?: boolean
  authoritativeReloadRequired: boolean

  constructor(opts: {
    method: string
    path: string
    status?: number
    statusText?: string
    timeout?: boolean
    timeoutMs?: number
    detail?: string
    errorCode?: string
    authErrorCode?: string
    responseData?: unknown
    configApplied?: boolean
    configApplicationState?: 'indeterminate'
    runtimeSync?: boolean
    authoritativeReloadRequired?: boolean
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
    this.authErrorCode = opts.authErrorCode?.trim() || undefined
    this.responseData = opts.responseData
    this.configApplied = opts.configApplied
    this.configApplicationState = opts.configApplicationState
    this.runtimeSync = opts.runtimeSync
    this.authoritativeReloadRequired = opts.authoritativeReloadRequired === true
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

/**
 * Control-plane operations complete when the server publishes their durable
 * outcome. A client-side wall-clock deadline can only hide that outcome while
 * the server continues the operation, so this boundary preserves only an
 * explicit caller-provided AbortSignal.
 */
export function fetchControlPlane(path: string, init: RequestInit): Promise<Response> {
  return fetch(path, {
    ...init,
    cache: init.cache ?? 'no-store',
  })
}

export async function fetchJsonWithTimeout(
  path: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<{ response: Response; data: unknown | null }> {
  const controller = new AbortController()
  const upstreamSignal = init.signal
  let rejectBoundary: (reason: unknown) => void = () => undefined
  const boundary = new Promise<never>((_resolve, reject) => {
    rejectBoundary = reject
  })
  const abortFromUpstream = () => {
    controller.abort()
    rejectBoundary(upstreamSignal?.reason ?? new DOMException('Aborted', 'AbortError'))
  }
  const timer = setTimeout(() => {
    controller.abort()
    const method = typeof init.method === 'string' ? init.method.toUpperCase() : 'GET'
    rejectBoundary(new ApiRequestError({ method, path, timeout: true, timeoutMs }))
  }, timeoutMs)

  if (upstreamSignal) {
    if (upstreamSignal.aborted) {
      controller.abort()
    } else {
      upstreamSignal.addEventListener('abort', abortFromUpstream, { once: true })
    }
  }

  try {
    const request = (async () => {
      const response = await fetch(path, {
        ...init,
        cache: init.cache ?? 'no-store',
        signal: controller.signal,
      })
      return {
        response,
        data: response.ok ? await response.json() : null,
      }
    })()
    return await Promise.race([request, boundary])
  } catch (err) {
    if (isAbortError(err)) {
      if (upstreamSignal?.aborted) throw err
      const method = typeof init.method === 'string' ? init.method.toUpperCase() : 'GET'
      throw new ApiRequestError({ method, path, timeout: true, timeoutMs })
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
  '/api/v1/dashboard/execution',
  '/api/v1/dashboard/planning',
  '/api/v1/dashboard/briefing',
])

/**
 * Routes whose polled body the browser may hold and revalidate.
 *
 * Reads default to `no-store`, so a body reaches the browser's HTTP cache only
 * when its route is listed here. Two conditions gate membership, both measured
 * against a running server rather than assumed:
 *
 *   1. The body repeats byte-identically across polls. A route whose body
 *      changes every poll can never answer 304, so listing it would buy a
 *      digest computation and nothing else. `/dashboard/bootstrap` and
 *      `/activity/events` fail this and are absent.
 *   2. The body carries no secret projection. `/keepers/composite` embeds
 *      `secret_projection` -- environment variable names and host paths, no
 *      values -- and listing a route is precisely what would put those on
 *      disk, so it stays `no-store` despite repeating byte-identically.
 * Baseline measured 2026-08-13 against a live server: initial routes carried
 * 1,741,479 of the 2,132,911 bytes one refresh cycle transfers (81.6%).
 * Expanded in 2026-09 to cover execution, config, keeper-memory-health, tasks history,
 * workspace, provider-logs, briefing, planning, and tool-metrics where server-side
 * weak ETags and 304 fast-paths eliminate repetitive JSON transfer and deserialization.
 * Condition 2 costs 49,743 of those bytes (2.3%); condition 1 excludes dynamic
 * non-repeatable routes that no caching strategy could recover.
 *
 * Listing a route cannot serve a stale body: `no-cache` stores the response but
 * revalidates before every use, so the server's ETag decides what the client
 * sees, not a client-side freshness window.
 */
const BROWSER_REVALIDATED_PATHS = new Set([
  '/api/v1/dashboard/scheduled-automation',
  '/api/v1/dashboard/telemetry',
  '/api/v1/dashboard/tool-quality',
  '/api/v1/dashboard/board',
  '/api/v1/board',
  '/api/v1/dashboard/harness-health',
  '/api/v1/agent-activity',
  '/api/v1/dashboard/goals',
  '/api/v1/dashboard/gate',
  '/api/v1/dashboard/execution',
  '/api/v1/dashboard/config',
  '/api/v1/dashboard/keeper-memory-health',
  '/api/v1/dashboard/tasks/history',
  '/api/v1/dashboard/workspace',
  '/api/v1/dashboard/provider-logs',
  '/api/v1/dashboard/briefing',
  '/api/v1/dashboard/planning',
  '/api/v1/tool-metrics',
])

/**
 * Eligibility belongs to the route, not to one request's parameters:
 * `/dashboard/telemetry?window=1h` is the same route as `/dashboard/telemetry`,
 * and several callers build paths that way. Matching the path as given would
 * silently miss every parameterised caller.
 *
 * Matching by prefix would fail in the other direction -- it would capture
 * `/dashboard/telemetry/summary`, a distinct route that was never measured. So
 * the query is split off and what remains is matched exactly.
 *
 * A route absent from the set gets `no-store`, which is what an unrecognised
 * path should get: the conservative answer, not the convenient one.
 */
export function readCacheMode(path: string): RequestCache {
  const queryStart = path.indexOf('?')
  const route = queryStart === -1 ? path : path.slice(0, queryStart)
  return BROWSER_REVALIDATED_PATHS.has(route) ? 'no-cache' : 'no-store'
}

import { isRecord } from '../lib/type-guards'

interface ErrorResponseInfo {
  detail?: string
  errorCode?: string
  authErrorCode?: string
  responseData?: unknown
  configApplied?: boolean
  configApplicationState?: 'indeterminate'
  runtimeSync?: boolean
  authoritativeReloadRequired?: boolean
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
      const jsonRpcError = isRecord(parsed.error) ? parsed.error : null
      const jsonRpcErrorData = jsonRpcError && isRecord(jsonRpcError.data)
        ? jsonRpcError.data
        : null
      const errorDetail = typeof parsed.error === 'string' ? parsed.error.trim() : ''
      const structuredErrorCode = typeof jsonRpcError?.code === 'string'
        ? jsonRpcError.code.trim()
        : ''
      const structuredErrorDetail = typeof jsonRpcError?.detail === 'string'
        ? jsonRpcError.detail.trim()
        : ''
      const topLevelAuthErrorCode = typeof parsed.auth_error_code === 'string'
        ? parsed.auth_error_code.trim()
        : ''
      const jsonRpcAuthErrorCode = typeof jsonRpcErrorData?.auth_error_code === 'string'
        ? jsonRpcErrorData.auth_error_code.trim()
        : ''
      const authErrorCode = topLevelAuthErrorCode || jsonRpcAuthErrorCode
      const errorCode =
        authErrorCode
        || (typeof parsed.error_code === 'string' ? parsed.error_code.trim() : '')
        || structuredErrorCode
        || (typeof parsed.status === 'string' ? parsed.status.trim() : '')
        || errorDetail
      const topLevelMessage = typeof parsed.message === 'string' ? parsed.message.trim() : ''
      const jsonRpcMessage = typeof jsonRpcError?.message === 'string'
        ? jsonRpcError.message.trim()
        : ''
      const message = topLevelMessage || jsonRpcMessage || structuredErrorDetail
      // The state key is the discriminator; counting fields would flip the
      // verdict the moment the server adds a detail field, exactly when the
      // operator most needs to know the write outcome is indeterminate.
      const configApplicationState = isRecord(parsed.config_application)
        && parsed.config_application.state === 'indeterminate'
        ? 'indeterminate' as const
        : undefined
      if (message || errorDetail || errorCode) {
        return {
          detail: message || errorDetail || errorCode || undefined,
          errorCode: errorCode || undefined,
          authErrorCode: authErrorCode || undefined,
          responseData: parsed,
          configApplied:
            typeof parsed.config_applied === 'boolean'
              ? parsed.config_applied
              : undefined,
          configApplicationState,
          runtimeSync: typeof parsed.runtime_sync === 'boolean'
            ? parsed.runtime_sync
            : undefined,
          authoritativeReloadRequired:
            parsed.authoritative_reload_required === true,
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
    authErrorCode: info.authErrorCode,
    responseData: info.responseData,
    configApplied: info.configApplied,
    configApplicationState: info.configApplicationState,
    runtimeSync: info.runtimeSync,
    authoritativeReloadRequired: info.authoritativeReloadRequired,
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

// The server answers a warm-up read with `{"status":"initializing"}` on
// /api/v1/dashboard/* paths and `{"error":"not initialized"}` elsewhere
// (lib/server/server_auth.ml not_initialized_response). Both mean the same
// thing: no state yet, try again.
function isNotInitializedEnvelope(raw: unknown): boolean {
  if (!isRecord(raw)) return false
  if (typeof raw.status === 'string' && raw.status === 'initializing') return true
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
    case '/api/v1/dashboard/briefing':
      return {
        generated_at: generatedAt,
        summary: {
          workspace_health: 'initializing',
        },
        incidents: [],
        recommended_actions: [],
        command_focus: {},
        operator_targets: { keepers: [], available_actions: [] },
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
      cache: readCacheMode(path),
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
      cache: readCacheMode(path),
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

export function runRequest<T>(_operation: string, run: () => Promise<T>): Promise<T> {
  return run()
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

export async function postControlPlane<T>(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  opts: AbortableRequestOptions = {},
): Promise<T> {
  const res = await fetchControlPlane(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
    signal: opts.signal,
  })
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

export async function runOperatorAction(
  body: OperatorActionRequest,
  opts: AbortableRequestOptions = {},
): Promise<OperatorActionResult> {
  const raw = await postControlPlane<unknown>(
    '/api/v1/operator/action',
    body,
    authHeaders({ actorName: body.actor }),
    opts,
  )
  const { parseOperatorActionResult } = await import('./schemas/operator-action')
  return parseOperatorActionResult(raw)
}

export async function confirmOperatorAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
  opts: AbortableRequestOptions = {},
): Promise<OperatorActionResult> {
  const raw = await postControlPlane<unknown>(
    '/api/v1/operator/confirm',
    {
      actor,
      confirm_token: confirmToken,
      decision,
    },
    authHeaders({ actorName: actor }),
    opts,
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

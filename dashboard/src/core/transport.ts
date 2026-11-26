/**
 * Mode-aware, epoch-fenced HTTP transport client.
 *
 * - `multi_account`: `credentials: 'same-origin'`, zero Bearer header, auto `x-masc-csrf-token`
 *   on unsafe methods (POST/PUT/PATCH/DELETE), single automatic CSRF refresh & retry on 403.
 * - `single_user`: `Authorization: Bearer <token>` when present + `credentials: 'same-origin'`.
 * - Epoch fence: captures `sessionEpoch` before dispatch; aborts automatically and drops
 *   stale responses (`kind: 'epoch_stale'`) if the Account or Workspace changed mid-flight.
 * - Typed wire envelope unwrappers matching live OCaml serializers (`V2Envelope`, `OkData`, Flat).
 */

import { ok, err, type Result } from '../lib/result'
import {
  authSession,
  currentSessionEpoch,
  getActiveCsrfToken,
  getSingleUserToken,
  isEpochCurrent,
  refreshMultiAccountCsrf,
  resolveWorkspaceUrl,
  sessionEpoch,
} from './auth'

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

export type ApiErrorKind =
  | 'aborted'
  | 'epoch_stale'
  | 'timeout'
  | 'network'
  | 'unauthorized'
  | 'forbidden'
  | 'csrf_rejected'
  | 'not_found'
  | 'conflict_cas'
  | 'validation'
  | 'server'
  | 'decode'

export interface ApiError {
  readonly kind: ApiErrorKind
  readonly status: number | null
  readonly code: string | null
  readonly message: string
  readonly retryable: boolean
  readonly field?: string
  readonly cause?: unknown
}

export interface ApiRequestOptions<T> {
  readonly method?: HttpMethod
  readonly path: string
  readonly body?: unknown
  readonly cache?: RequestCache
  readonly headers?: Record<string, string>
  readonly signal?: AbortSignal
  readonly fetchImpl?: typeof fetch
  readonly decode?: (raw: unknown) => T
  readonly envelope?: 'flat' | 'v2' | 'ok_data'
  /** Optional per-attempt total deadline (headers + body). Disabled (0) by default. */
  readonly timeoutMs?: number
}

export interface V2Envelope<T> {
  readonly schema_version: number
  readonly instance_id: string
  readonly generated_at_unix: number
  readonly data: T
}

export type OkDataEnvelope<T> =
  | { readonly ok: true; readonly data: T }
  | { readonly ok: false; readonly error: string; readonly code?: string }

const UNSAFE_METHODS: ReadonlySet<HttpMethod> = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function classifyHttpError(status: number, body: unknown): ApiError {
  let code: string | null = null
  let message = `HTTP ${status}`
  let field: string | undefined

  if (isRecord(body)) {
    if (isRecord(body.error)) {
      if (typeof body.error.code === 'string') code = body.error.code
      if (typeof body.error.message === 'string') message = body.error.message
      if (typeof body.error.field === 'string') field = body.error.field
    } else if (typeof body.error === 'string') {
      message = body.error
      if (typeof body.code === 'string') code = body.code
    } else if (typeof body.message === 'string') {
      message = body.message
      if (typeof body.code === 'string') code = body.code
    }
  }

  if (status === 401) {
    return { kind: 'unauthorized', status, code, message, retryable: false, field }
  }
  if (status === 403) {
    const isCsrf = code === 'csrf_invalid' || code === 'csrf_missing' || /\bcsrf\b/i.test(message)
    return { kind: isCsrf ? 'csrf_rejected' : 'forbidden', status, code, message, retryable: false, field }
  }
  if (status === 404) {
    return { kind: 'not_found', status, code, message, retryable: false, field }
  }
  if (status === 409) {
    return { kind: 'conflict_cas', status, code, message, retryable: false, field }
  }
  if (status >= 400 && status < 500) {
    return { kind: 'validation', status, code, message, retryable: false, field }
  }
  return { kind: 'server', status, code, message, retryable: status >= 500, field }
}

export function unwrapV2Envelope<T>(raw: unknown): Result<T, ApiError> {
  if (!isRecord(raw)) {
    return err({ kind: 'decode', status: 200, code: 'invalid_envelope', message: 'Expected V2 JSON object', retryable: false })
  }
  if (isRecord(raw.error)) {
    const code = typeof raw.error.code === 'string' ? raw.error.code : 'v2_error'
    const message = typeof raw.error.message === 'string' ? raw.error.message : 'Server error'
    const field = typeof raw.error.field === 'string' ? raw.error.field : undefined
    const kind: ApiErrorKind = code === 'conflict_cas' ? 'conflict_cas'
      : code === 'unauthorized' ? 'unauthorized'
      : code === 'not_found' ? 'not_found'
      : code === 'store_unavailable' ? 'server'
      : 'validation'
    return err({ kind, status: null, code, message, retryable: kind === 'server', field })
  }
  if (!('data' in raw)) {
    return err({ kind: 'decode', status: 200, code: 'missing_data', message: 'V2 envelope missing data field', retryable: false })
  }
  return ok(raw.data as T)
}

export function unwrapOkData<T>(raw: unknown): Result<T, ApiError> {
  if (!isRecord(raw) || typeof raw.ok !== 'boolean') {
    return err({ kind: 'decode', status: 200, code: 'invalid_ok_envelope', message: 'Expected { ok, data } object', retryable: false })
  }
  if (!raw.ok) {
    return err({
      kind: 'validation',
      status: 200,
      code: typeof raw.code === 'string' ? raw.code : 'not_ok',
      message: typeof raw.error === 'string' ? raw.error : 'Request failed',
      retryable: false,
    })
  }
  return ok(raw.data as T)
}

function buildHeaders(
  method: HttpMethod,
  hasBody: boolean,
  extra?: Record<string, string>,
): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    ...extra,
  }
  if (hasBody && !('Content-Type' in headers)) {
    headers['Content-Type'] = 'application/json'
  }
  const session = authSession.peek()
  if (session.kind === 'multi_account_signed_in') {
    if (UNSAFE_METHODS.has(method)) {
      const csrf = getActiveCsrfToken()
      if (csrf) headers['x-masc-csrf-token'] = csrf
    }
  } else {
    const token = getSingleUserToken()
    if (token && !('Authorization' in headers)) {
      headers.Authorization = `Bearer ${token}`
    }
  }
  return headers
}

export async function apiRequest<T>(opts: ApiRequestOptions<T>): Promise<Result<T, ApiError>> {
  const method: HttpMethod = opts.method ?? 'GET'
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  const controller = new AbortController()

  const onCallerAbort = () => controller.abort(opts.signal?.reason)
  if (opts.signal) {
    if (opts.signal.aborted) {
      return err({ kind: 'aborted', status: null, code: null, message: 'Request aborted', retryable: false })
    }
    opts.signal.addEventListener('abort', onCallerAbort, { once: true })
  }

  const unsubEpoch = sessionEpoch.subscribe((epoch) => {
    if (epoch !== startEpoch) {
      controller.abort('epoch_stale')
    }
  })

  const executeOnce = async (): Promise<Result<T, ApiError>> => {
    if (!isEpochCurrent(startEpoch)) {
      return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Session epoch changed', retryable: false })
    }
    if (controller.signal.aborted) {
      return err({ kind: 'aborted', status: null, code: null, message: 'Request aborted', retryable: false })
    }

    const timeoutMs = opts.timeoutMs ?? 0
    const attemptController = new AbortController()
    let timedOut = false
    const onParentAbort = () => attemptController.abort(controller.signal.reason)
    controller.signal.addEventListener('abort', onParentAbort, { once: true })

    let timeoutTimer: ReturnType<typeof setTimeout> | null = null
    const deadlinePromise = new Promise<never>((_resolve, reject) => {
      const onAttemptAbort = () => {
        reject(new Error(timedOut ? `Request timed out after ${timeoutMs}ms` : 'Request aborted'))
      }
      attemptController.signal.addEventListener('abort', onAttemptAbort, { once: true })
      if (timeoutMs > 0) {
        timeoutTimer = setTimeout(() => {
          timedOut = true
          attemptController.abort('timeout')
        }, timeoutMs)
      }
    })
    // Prevent unhandled rejection when request finishes before abort/timeout
    deadlinePromise.catch(() => {})

    const hasBody = opts.body !== undefined
    const init: RequestInit = {
      method,
      credentials: 'same-origin',
      headers: buildHeaders(method, hasBody, opts.headers),
      signal: attemptController.signal,
      ...(opts.cache && { cache: opts.cache }),
      ...(hasBody ? { body: typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body) } : {}),
    }

    try {
      let response: Response
      try {
        response = await Promise.race([
          fetchImpl(resolveWorkspaceUrl(opts.path), init),
          deadlinePromise,
        ])
      } catch (cause) {
        if (!isEpochCurrent(startEpoch)) {
          return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Session epoch changed', retryable: false, cause })
        }
        if (timedOut) {
          return err({
            kind: 'timeout',
            status: null,
            code: 'request_timeout',
            message: `Request timed out after ${timeoutMs}ms`,
            retryable: true,
            cause,
          })
        }
        if (attemptController.signal.aborted || controller.signal.aborted) {
          return err({ kind: 'aborted', status: null, code: null, message: 'Request aborted', retryable: false, cause })
        }
        return err({
          kind: 'network',
          status: null,
          code: 'network_error',
          message: cause instanceof Error ? cause.message : String(cause),
          retryable: true,
          cause,
        })
      }

      if (!isEpochCurrent(startEpoch)) {
        return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Dropped stale response after epoch change', retryable: false })
      }

      let parsedBody: unknown = null
      if (response.status !== 204) {
        const contentType = response.headers.get('content-type') ?? ''
        try {
          parsedBody = await Promise.race([
            contentType.includes('application/json') || contentType === ''
              ? response.json()
              : response.text(),
            deadlinePromise,
          ])
        } catch (cause) {
          if (!isEpochCurrent(startEpoch)) {
            return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Session epoch changed', retryable: false, cause })
          }
          if (timedOut) {
            return err({
              kind: 'timeout',
              status: null,
              code: 'request_timeout',
              message: `Response body timed out after ${timeoutMs}ms`,
              retryable: true,
              cause,
            })
          }
          if (attemptController.signal.aborted || controller.signal.aborted) {
            return err({ kind: 'aborted', status: null, code: null, message: 'Request aborted', retryable: false, cause })
          }
          if (!response.ok) {
            return err(classifyHttpError(response.status, null))
          }
          return err({
            kind: 'decode',
            status: response.status,
            code: 'invalid_json',
            message: 'Failed to parse JSON response',
            retryable: false,
            cause,
          })
        }
      }

      if (!isEpochCurrent(startEpoch)) {
        return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Dropped stale response after epoch change', retryable: false })
      }

      if (!response.ok) {
        return err(classifyHttpError(response.status, parsedBody))
      }

      let payload: unknown = parsedBody
      if (opts.envelope === 'v2') {
        const unwrapped = unwrapV2Envelope<unknown>(parsedBody)
        if (!unwrapped.ok) return unwrapped
        payload = unwrapped.value
      } else if (opts.envelope === 'ok_data') {
        const unwrapped = unwrapOkData<unknown>(parsedBody)
        if (!unwrapped.ok) return unwrapped
        payload = unwrapped.value
      }

      if (opts.decode) {
        try {
          return ok(opts.decode(payload))
        } catch (cause) {
          return err({
            kind: 'decode',
            status: response.status,
            code: 'schema_drift',
            message: cause instanceof Error ? cause.message : String(cause),
            retryable: false,
            cause,
          })
        }
      }
      return ok(payload as T)
    } finally {
      if (timeoutTimer !== null) clearTimeout(timeoutTimer)
      controller.signal.removeEventListener('abort', onParentAbort)
    }
  }

  try {
    const prevCsrf = getActiveCsrfToken()
    const first = await executeOnce()
    if (
      !first.ok
      && first.error.kind === 'csrf_rejected'
      && UNSAFE_METHODS.has(method)
      && authSession.peek().kind === 'multi_account_signed_in'
      && isEpochCurrent(startEpoch)
    ) {
      const refreshed = await refreshMultiAccountCsrf(fetchImpl)
      if (refreshed && refreshed !== prevCsrf && isEpochCurrent(startEpoch)) {
        return await executeOnce()
      }
    }
    return first
  } finally {
    unsubEpoch()
    if (opts.signal) opts.signal.removeEventListener('abort', onCallerAbort)
  }
}

export function apiGet<T>(
  path: string,
  opts: Omit<ApiRequestOptions<T>, 'method' | 'path' | 'body'> = {},
): Promise<Result<T, ApiError>> {
  return apiRequest<T>({ ...opts, method: 'GET', path })
}

export function apiGetV2<T>(
  path: string,
  opts: Omit<ApiRequestOptions<T>, 'method' | 'path' | 'body' | 'envelope'> = {},
): Promise<Result<T, ApiError>> {
  return apiRequest<T>({ ...opts, method: 'GET', path, envelope: 'v2' })
}

export function apiMutate<T>(
  method: Exclude<HttpMethod, 'GET'>,
  path: string,
  body?: unknown,
  opts: Omit<ApiRequestOptions<T>, 'method' | 'path' | 'body'> = {},
): Promise<Result<T, ApiError>> {
  return apiRequest<T>({ ...opts, method, path, body })
}

export function apiMutateV2<T>(
  method: Exclude<HttpMethod, 'GET'>,
  path: string,
  body?: unknown,
  opts: Omit<ApiRequestOptions<T>, 'method' | 'path' | 'body' | 'envelope'> = {},
): Promise<Result<T, ApiError>> {
  return apiRequest<T>({ ...opts, method, path, body, envelope: 'v2' })
}

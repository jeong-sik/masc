/**
 * Mode-aware, epoch-fenced SSE client for Provider Subscription CLI OAuth Login
 * (`POST /api/v1/setup/accounts/login`, `/input`, `/cancel`).
 *
 * Authoritative wire contract: `lib/server/server_setup_account_login.ml:251-414`
 * & `lib/runtime/runtime_setup_login_session.ml:34-47`.
 * - Reads `text/event-stream` (`started`, `output`, `screen`, `auth_url`,
 *   `device_code`, `input_ready`, `complete`, `error`).
 * - Strips ANSI escapes and auto-extracts `https://` OAuth URLs & device codes
 *   so callers can auto-open the browser once per session without manual copy/paste.
 */

import {
  authSession,
  currentSessionEpoch,
  getActiveCsrfToken,
  getSingleUserToken,
  isEpochCurrent,
  resolveWorkspaceUrl,
  sessionEpoch,
} from './auth'
import { apiMutate, type ApiError } from './transport'
import type { Result } from '../lib/result'

export interface SetupLoginReceipt {
  readonly loginId: string
  readonly integrationId: string
  readonly status: string
  readonly accountRef: string | null
  readonly authentication: string | null
}

export type SetupLoginInputPayload =
  | { readonly kind: 'text'; readonly text: string }
  | { readonly kind: 'key'; readonly key: 'enter' | 'up' | 'down' | 'tab' | 'eof' }

export interface SetupLoginStreamCallbacks {
  readonly onStarted?: (receipt: SetupLoginReceipt) => void
  readonly onOutput?: (stream: 'stdout' | 'stderr', text: string) => void
  readonly onScreen?: (text: string) => void
  readonly onAuthUrl?: (url: string) => void
  readonly onDeviceCode?: (code: string, url?: string | null) => void
  readonly onInputReady?: () => void
  readonly onComplete?: (receipt: SetupLoginReceipt) => void
  readonly onError?: (message: string, receipt?: SetupLoginReceipt | null) => void
}

export interface StreamSetupLoginOutcome {
  readonly terminal: boolean
  readonly completed: boolean
  readonly loginId: string | null
  readonly error: string | null
}

// eslint-disable-next-line no-control-regex
const ANSI_ESCAPE_RE = /\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|\[[0-9;?]*[ -/]*[@-~])/g
const HTTPS_URL_RE = /https:\/\/[^\s"'<>()[\]]+/gi
const DEVICE_CODE_CONTEXT_RE = /(?:code|enter|one-time|verify)[^A-Z0-9\n]{0,24}\b([A-Z0-9]{4}-[A-Z0-9]{4,5})\b/i
const BARE_DEVICE_CODE_RE = /\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/

export function stripAnsi(text: string): string {
  return text.replace(ANSI_ESCAPE_RE, '')
}

export function extractOAuthUrl(rawText: string): string | null {
  const clean = stripAnsi(rawText)
  const matches = clean.match(HTTPS_URL_RE)
  if (!matches) return null
  for (const raw of matches) {
    const trimmed = raw.replace(/[.,;:!?)'"\]]+$/, '')
    try {
      const parsed = new URL(trimmed)
      if (parsed.protocol === 'https:') {
        return parsed.toString()
      }
    } catch {
      // keep scanning
    }
  }
  return null
}

export function extractDeviceCode(rawText: string): string | null {
  const clean = stripAnsi(rawText)
  const ctx = DEVICE_CODE_CONTEXT_RE.exec(clean)
  if (ctx?.[1]) return ctx[1].toUpperCase()
  const bare = BARE_DEVICE_CODE_RE.exec(clean)
  if (bare?.[1] && /[A-Z]/.test(bare[1]) && /[0-9]/.test(bare[1])) {
    return bare[1].toUpperCase()
  }
  return null
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asNonEmptyStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

export function decodeSetupLoginReceipt(
  raw: unknown,
  fallbackIntegrationId: string,
  fallbackLoginId = '',
): SetupLoginReceipt {
  const rec = isRecord(raw) ? raw : {}
  const account = isRecord(rec.account) ? rec.account : null
  const accountRef =
    asNonEmptyStr(rec.account_ref)
    ?? asNonEmptyStr(rec.provider_account_id)
    ?? (account ? (asNonEmptyStr(account.reference) ?? asNonEmptyStr(account.account_ref)) : null)
  return {
    loginId: asNonEmptyStr(rec.login_id) ?? fallbackLoginId,
    integrationId: asNonEmptyStr(rec.integration_id) ?? fallbackIntegrationId,
    status: asNonEmptyStr(rec.status) ?? 'running',
    accountRef,
    authentication: asNonEmptyStr(rec.authentication),
  }
}

function buildSsePostHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: 'text/event-stream',
    'Content-Type': 'application/json',
  }
  const session = authSession.peek()
  if (session.kind === 'multi_account_signed_in') {
    const csrf = getActiveCsrfToken()
    if (csrf) headers['x-masc-csrf-token'] = csrf
  } else {
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }
  return headers
}

/**
 * Streams `POST /api/v1/setup/accounts/login` as SSE (`text/event-stream`) with
 * epoch-fenced cancellation and automatic ANSI-stripped OAuth URL & device-code extraction.
 */
export async function streamSetupAccountLogin(params: {
  readonly integrationId: string
  readonly accountRef?: string
  readonly signal?: AbortSignal
  readonly fetchImpl?: typeof fetch
  readonly callbacks: SetupLoginStreamCallbacks
}): Promise<StreamSetupLoginOutcome> {
  const fetchImpl = params.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  if (params.signal?.aborted) {
    return { terminal: false, completed: false, loginId: null, error: 'aborted' }
  }

  const controller = new AbortController()
  const onExternalAbort = () => controller.abort(params.signal?.reason)
  params.signal?.addEventListener('abort', onExternalAbort, { once: true })
  const unsubEpoch = sessionEpoch.subscribe((ep) => {
    if (ep !== startEpoch && !controller.signal.aborted) {
      controller.abort('session_epoch_changed')
    }
  })

  const body: Record<string, string> = { integration_id: params.integrationId }
  if (params.accountRef?.trim()) {
    body.account_ref = params.accountRef.trim()
  }

  let currentLoginId: string | null = null
  let terminal = false
  let completed = false
  let lastError: string | null = null
  let announcedUrl: string | null = null
  let announcedCode: string | null = null

  const maybeNotifyExtracted = (text: string) => {
    const url = extractOAuthUrl(text)
    if (url && url !== announcedUrl) {
      announcedUrl = url
      params.callbacks.onAuthUrl?.(url)
    }
    const code = extractDeviceCode(text)
    if (code && code !== announcedCode) {
      announcedCode = code
      params.callbacks.onDeviceCode?.(code, announcedUrl)
    }
  }

  const handleFrame = (rawFrame: string) => {
    if (!isEpochCurrent(startEpoch) || controller.signal.aborted) return
    let eventName = 'message'
    const dataLines: string[] = []
    for (const line of rawFrame.split(/\r?\n/)) {
      if (line.startsWith('event:')) {
        eventName = line.slice(6).trim()
      } else if (line.startsWith('data:')) {
        dataLines.push(line.slice(5).trimStart())
      }
    }
    if (dataLines.length === 0) return
    const rawData = dataLines.join('\n')
    let parsed: unknown = null
    try {
      parsed = JSON.parse(rawData)
    } catch {
      parsed = null
    }

    if (eventName === 'started') {
      const receipt = decodeSetupLoginReceipt(parsed, params.integrationId)
      if (receipt.loginId) currentLoginId = receipt.loginId
      params.callbacks.onStarted?.(receipt)
      return
    }
    if (eventName === 'output' && isRecord(parsed)) {
      const stream = parsed.stream === 'stderr' ? 'stderr' : 'stdout'
      const text = typeof parsed.text === 'string' ? stripAnsi(parsed.text) : ''
      if (text) {
        params.callbacks.onOutput?.(stream, text)
        maybeNotifyExtracted(text)
      }
      return
    }
    if (eventName === 'screen' && isRecord(parsed)) {
      const text = typeof parsed.text === 'string' ? stripAnsi(parsed.text) : ''
      if (text) {
        params.callbacks.onScreen?.(text)
        maybeNotifyExtracted(text)
      }
      return
    }
    if (eventName === 'auth_url' && isRecord(parsed)) {
      const url = extractOAuthUrl(String(parsed.url ?? ''))
      if (url && url !== announcedUrl) {
        announcedUrl = url
        params.callbacks.onAuthUrl?.(url)
      }
      return
    }
    if (eventName === 'device_code' && isRecord(parsed)) {
      const code = asNonEmptyStr(parsed.code ?? parsed.user_code)
      const url = typeof parsed.url === 'string' ? extractOAuthUrl(parsed.url) : announcedUrl
      if (url && url !== announcedUrl) {
        announcedUrl = url
        params.callbacks.onAuthUrl?.(url)
      }
      if (code && code !== announcedCode) {
        announcedCode = code
        params.callbacks.onDeviceCode?.(code, url)
      }
      return
    }
    if (eventName === 'input_ready') {
      params.callbacks.onInputReady?.()
      return
    }
    if (eventName === 'complete') {
      const receipt = decodeSetupLoginReceipt(parsed, params.integrationId, currentLoginId ?? '')
      if (receipt.loginId) currentLoginId = receipt.loginId
      terminal = true
      completed = true
      params.callbacks.onComplete?.({ ...receipt, status: 'complete' })
      return
    }
    if (eventName === 'error') {
      const rec = isRecord(parsed) ? parsed : {}
      const msg = asNonEmptyStr(rec.message) ?? asNonEmptyStr(rec.error) ?? 'CLI OAuth 로그인이 완료되지 않았습니다.'
      const receipt = isRecord(parsed) && (rec.login_id || rec.status)
        ? decodeSetupLoginReceipt(parsed, params.integrationId, currentLoginId ?? '')
        : null
      if (receipt?.loginId) currentLoginId = receipt.loginId
      terminal = true
      lastError = msg
      params.callbacks.onError?.(msg, receipt)
    }
  }

  try {
    const res = await fetchImpl(resolveWorkspaceUrl('/api/v1/setup/accounts/login'), {
      method: 'POST',
      credentials: 'same-origin',
      headers: buildSsePostHeaders(),
      body: JSON.stringify(body),
      signal: controller.signal,
    })

    if (!isEpochCurrent(startEpoch)) {
      return { terminal: false, completed: false, loginId: currentLoginId, error: 'session_epoch_changed' }
    }

    if (!res.ok) {
      let msg = `HTTP ${res.status}`
      try {
        const text = await res.text()
        const json: unknown = JSON.parse(text)
        if (isRecord(json)) {
          msg = asNonEmptyStr(json.error) ?? asNonEmptyStr(json.message) ?? msg
        } else if (text.trim()) {
          msg = text.trim()
        }
      } catch {
        // keep HTTP status fallback
      }
      params.callbacks.onError?.(msg, null)
      return { terminal: true, completed: false, loginId: null, error: msg }
    }

    const contentType = res.headers.get('content-type') ?? ''
    // Fallback if a proxy/test responded with a single JSON receipt
    if (contentType.includes('application/json')) {
      const payload: unknown = await res.json().catch(() => ({}))
      const receipt = decodeSetupLoginReceipt(payload, params.integrationId)
      currentLoginId = receipt.loginId || null
      params.callbacks.onStarted?.(receipt)
      if (receipt.status === 'complete' || receipt.status === 'completed') {
        params.callbacks.onComplete?.(receipt)
        return { terminal: true, completed: true, loginId: currentLoginId, error: null }
      }
      return { terminal: false, completed: false, loginId: currentLoginId, error: null }
    }

    if (!res.body) {
      const msg = 'SSE 스트림 본문이 비어 있습니다.'
      params.callbacks.onError?.(msg, null)
      return { terminal: true, completed: false, loginId: currentLoginId, error: msg }
    }

    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    let buf = ''
    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        const parts = buf.split(/\r?\n\r?\n/)
        buf = parts.pop() ?? ''
        for (const frame of parts) {
          if (frame.trim()) handleFrame(frame)
        }
      }
      buf += decoder.decode()
      if (buf.trim()) handleFrame(buf)
    } finally {
      reader.releaseLock()
    }

    return { terminal, completed, loginId: currentLoginId, error: lastError }
  } catch (e: unknown) {
    if (controller.signal.aborted) {
      return { terminal: false, completed: false, loginId: currentLoginId, error: 'aborted' }
    }
    const msg = e instanceof Error ? e.message : String(e)
    params.callbacks.onError?.(msg, null)
    return { terminal: true, completed: false, loginId: currentLoginId, error: msg }
  } finally {
    params.signal?.removeEventListener('abort', onExternalAbort)
    unsubEpoch()
  }
}

export function sendSetupLoginInput(
  loginId: string,
  payload: SetupLoginInputPayload,
): Promise<Result<{ readonly accepted?: boolean }, ApiError>> {
  return apiMutate<{ readonly accepted?: boolean }>(
    'POST',
    `/api/v1/setup/accounts/login/${encodeURIComponent(loginId)}/input`,
    payload,
  )
}

export function cancelSetupLogin(
  loginId: string,
): Promise<Result<{ readonly accepted?: boolean }, ApiError>> {
  return apiMutate<{ readonly accepted?: boolean }>(
    'POST',
    `/api/v1/setup/accounts/login/${encodeURIComponent(loginId)}/cancel`,
    {},
  )
}

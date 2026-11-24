/**
 * Zero-Manual Keeper OAuth Flow Engine (`#131` Flow 2).
 *
 * Shared by BOTH `5 Runtime > Tools (Keeper OAuth)` and `4 Keepers > Config`:
 * 1. Synchronous popup open on click (avoids browser popup blockers) -> navigate to
 *    validated `authorize_url` -> same-origin `postMessage('masc:oauth-complete')`
 *    listener + 1.5s auto-poll `GET /api/v1/keepers/oauth/attempt-status` until
 *    terminal -> auto-refresh attached tools!
 * 2. GitHub CLI SSE device-flow stream (`POST /api/v1/keepers/:k/github-login`)
 *    with automatic ANSI stripping, URL extraction + auto-open, and copyable
 *    one-time device code (`XXXX-XXXX`).
 * 3. Custom OAuth App registration (`POST /api/v1/keepers/oauth/client`) and
 *    explicit disconnect (`POST /api/v1/keepers/oauth/disconnect`).
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
import { apiGet, apiMutate, type ApiError } from './transport'
import { extractDeviceCode, extractOAuthUrl, stripAnsi } from './setup-login-stream'
import type { Result } from '../lib/result'

export type OAuthAttemptKind =
  | 'awaiting_consent'
  | 'callback_admitted'
  | 'completed'
  | 'failed'
  | 'credential_publication_incomplete'
  | 'expired'
  | 'superseded'
  | 'unavailable'

export interface OAuthAttemptStatus {
  readonly kind: OAuthAttemptKind
  readonly toolCount?: number
  readonly discoveryFailed?: boolean
  readonly raw?: Record<string, unknown>
}

export interface ActiveKeeperOAuthFlow {
  readonly keeper: string
  readonly provider: string
  readonly providerLabel: string
  readonly mode: 'oauth_popup' | 'github_device'
  readonly phase: 'starting' | 'awaiting_user' | 'completing' | 'completed' | 'failed'
  readonly authorizeUrl: string | null
  readonly deviceCode: string | null
  readonly attemptId: string | null
  readonly popupBlocked: boolean
  readonly message: string
  readonly logTail: string
}

export interface KeeperOAuthFlowHandle {
  readonly cancel: () => void
}

const TERMINAL_ATTEMPT_KINDS = new Set<OAuthAttemptKind>([
  'completed',
  'failed',
  'credential_publication_incomplete',
  'expired',
  'superseded',
  'unavailable',
])

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function parseSafeHttpUrl(raw: unknown): string | null {
  if (typeof raw !== 'string' || !raw.trim()) return null
  try {
    const parsed = new URL(raw.trim())
    if (parsed.protocol === 'https:' || parsed.protocol === 'http:') {
      return parsed.toString()
    }
    return null
  } catch {
    return null
  }
}

export function decodeOAuthAttemptStatus(raw: unknown): OAuthAttemptStatus {
  if (!isRecord(raw)) return { kind: 'unavailable' }
  const kindRaw = typeof raw.kind === 'string' ? raw.kind : 'unavailable'
  const kind: OAuthAttemptKind =
    kindRaw === 'awaiting_consent'
    || kindRaw === 'callback_admitted'
    || kindRaw === 'completed'
    || kindRaw === 'failed'
    || kindRaw === 'credential_publication_incomplete'
    || kindRaw === 'expired'
    || kindRaw === 'superseded'
      ? kindRaw
      : 'unavailable'
  const td = isRecord(raw.tool_discovery) ? raw.tool_discovery : null
  const toolCount = td && typeof td.count === 'number' ? td.count : undefined
  const discoveryFailed = td ? td.kind === 'failed' : undefined
  return { kind, toolCount, discoveryFailed, raw }
}

export function isTerminalOAuthAttemptKind(kind: OAuthAttemptKind): boolean {
  return TERMINAL_ATTEMPT_KINDS.has(kind)
}

export function startKeeperOAuthPopupFlow(params: {
  readonly keeper: string
  readonly provider: string
  readonly providerLabel: string
  readonly pollIntervalMs?: number
  readonly onUpdate: (state: ActiveKeeperOAuthFlow) => void
  readonly onSettled: (succeeded: boolean) => void
}): KeeperOAuthFlowHandle {
  const startEpoch = currentSessionEpoch()
  let disposed = false
  let pollTimer: ReturnType<typeof setInterval> | null = null
  let popup: Window | null = null

  // Open popup synchronously inside user click event so popup blockers allow it!
  if (typeof window !== 'undefined' && typeof window.open === 'function') {
    try {
      popup = window.open('about:blank', 'masc_keeper_oauth', 'popup=yes,width=640,height=760')
    } catch {
      popup = null
    }
  }
  const popupBlocked = popup === null

  let state: ActiveKeeperOAuthFlow = {
    keeper: params.keeper,
    provider: params.provider,
    providerLabel: params.providerLabel,
    mode: 'oauth_popup',
    phase: 'starting',
    authorizeUrl: null,
    deviceCode: null,
    attemptId: null,
    popupBlocked,
    message: `${params.providerLabel} OAuth 인증 시작 중…`,
    logTail: '',
  }

  const emit = (patch: Partial<ActiveKeeperOAuthFlow>) => {
    if (disposed) return
    state = { ...state, ...patch }
    params.onUpdate(state)
  }

  const cleanup = () => {
    if (disposed) return
    disposed = true
    if (pollTimer !== null) {
      clearInterval(pollTimer)
      pollTimer = null
    }
    if (typeof window !== 'undefined') {
      window.removeEventListener('message', onPostMessage)
    }
    unsubEpoch()
    try {
      if (popup && !popup.closed) popup.close()
    } catch {
      // cross-origin window close best-effort
    }
  }

  const settle = (succeeded: boolean, patch: Partial<ActiveKeeperOAuthFlow>) => {
    if (disposed) return
    state = { ...state, ...patch }
    params.onUpdate(state)
    cleanup()
    params.onSettled(succeeded)
  }

  const onPostMessage = (ev: MessageEvent) => {
    if (disposed || typeof window === 'undefined') return
    if (ev.origin !== window.location.origin) return
    if (!isRecord(ev.data) || ev.data.type !== 'masc:oauth-complete') return
    if (ev.data.keeper && ev.data.keeper !== params.keeper) return
    if (ev.data.provider && ev.data.provider !== params.provider) return
    settle(true, {
      phase: 'completed',
      message: `${params.providerLabel} OAuth 연결 완료 — 도구 목록을 자동 갱신합니다.`,
    })
  }

  const unsubEpoch = sessionEpoch.subscribe((ep) => {
    if (ep !== startEpoch) cleanup()
  })

  if (typeof window !== 'undefined') {
    window.addEventListener('message', onPostMessage)
  }

  emit({})

  void (async () => {
    const res = await apiMutate<Record<string, unknown>>(
      'POST',
      `/api/v1/keepers/${encodeURIComponent(params.keeper)}/oauth-login`,
      { provider: params.provider },
    )
    if (disposed || !isEpochCurrent(startEpoch)) return

    if (!res.ok) {
      settle(false, {
        phase: 'failed',
        message: `OAuth 시작 실패: ${res.error.message}`,
      })
      return
    }

    // Immediate attachment (e.g., github_cli already authenticated)
    if (res.value.attached === true && !res.value.authorize_url) {
      const msg = typeof res.value.message === 'string'
        ? res.value.message
        : `${params.providerLabel} 연결 완료`
      settle(true, { phase: 'completed', message: msg })
      return
    }

    const safeUrl = parseSafeHttpUrl(res.value.authorize_url)
    const attemptId = typeof res.value.attempt_id === 'string' && res.value.attempt_id.trim()
      ? res.value.attempt_id.trim()
      : null

    if (!safeUrl) {
      settle(false, {
        phase: 'failed',
        message: '유효한 OAuth 인증 URL을 받지 못했습니다.',
      })
      return
    }

    let openedOk = false
    if (popup && !popup.closed) {
      try {
        popup.location.href = safeUrl
        openedOk = true
      } catch {
        openedOk = false
      }
    }

    emit({
      phase: 'awaiting_user',
      authorizeUrl: safeUrl,
      attemptId,
      popupBlocked: !openedOk,
      message: openedOk
        ? `${params.providerLabel} 인증 창이 열렸습니다. 승인을 마치면 자동으로 연결됩니다.`
        : `${params.providerLabel} 인증 링크가 준비되었습니다 (팝업이 차단된 경우 아래 버튼을 클릭하세요).`,
    })

    if (!attemptId) return

    const pollOnce = async () => {
      if (disposed || !isEpochCurrent(startEpoch)) return
      const qs = new URLSearchParams({
        keeper: params.keeper,
        provider: params.provider,
        attempt_id: attemptId,
      })
      const statusRes = await apiGet<unknown>(`/api/v1/keepers/oauth/attempt-status?${qs.toString()}`)
      if (disposed || !isEpochCurrent(startEpoch) || !statusRes.ok) return
      const parsed = decodeOAuthAttemptStatus(statusRes.value)
      if (parsed.kind === 'callback_admitted') {
        emit({ phase: 'completing', message: `${params.providerLabel} 콜백 확인 중 — 도구 목록을 동기화하고 있습니다…` })
        return
      }
      if (!isTerminalOAuthAttemptKind(parsed.kind)) return

      if (parsed.kind === 'completed') {
        const suffix = parsed.discoveryFailed
          ? ' (자격 증명은 저장되었으나 도구 검색이 실패했습니다)'
          : typeof parsed.toolCount === 'number'
            ? ` (도구 ${parsed.toolCount}개 발견)`
            : ''
        settle(true, {
          phase: 'completed',
          message: `${params.providerLabel} 연결 완료${suffix}.`,
        })
      } else {
        settle(false, {
          phase: 'failed',
          message: `${params.providerLabel} OAuth 실패 (${parsed.kind}).`,
        })
      }
    }

    pollTimer = setInterval(() => {
      void pollOnce()
    }, params.pollIntervalMs ?? 1500)
  })()

  return { cancel: cleanup }
}

/**
 * Streams `POST /api/v1/keepers/:k/github-login` SSE device flow, automatically
 * extracting the GitHub device URL & one-time code and opening the verification tab once.
 */
export function startKeeperGithubDeviceFlow(params: {
  readonly keeper: string
  readonly providerLabel?: string
  readonly fetchImpl?: typeof fetch
  readonly onUpdate: (state: ActiveKeeperOAuthFlow) => void
  readonly onSettled: (succeeded: boolean) => void
}): KeeperOAuthFlowHandle {
  const fetchImpl = params.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  const controller = new AbortController()
  let disposed = false
  let openedUrl = false

  let state: ActiveKeeperOAuthFlow = {
    keeper: params.keeper,
    provider: 'github',
    providerLabel: params.providerLabel ?? 'GitHub',
    mode: 'github_device',
    phase: 'starting',
    authorizeUrl: null,
    deviceCode: null,
    attemptId: null,
    popupBlocked: false,
    message: 'GitHub CLI 디바이스 로그인 스트림을 시작하는 중…',
    logTail: '',
  }

  const emit = (patch: Partial<ActiveKeeperOAuthFlow>) => {
    if (disposed) return
    state = { ...state, ...patch }
    params.onUpdate(state)
  }

  const unsubEpoch = sessionEpoch.subscribe((ep) => {
    if (ep !== startEpoch) {
      disposed = true
      controller.abort('session_epoch_changed')
    }
  })

  emit({})

  void (async () => {
    const headers: Record<string, string> = { Accept: 'text/event-stream' }
    const session = authSession.peek()
    if (session.kind === 'multi_account_signed_in') {
      const csrf = getActiveCsrfToken()
      if (csrf) headers['x-masc-csrf-token'] = csrf
    } else {
      const token = getSingleUserToken()
      if (token) headers.Authorization = `Bearer ${token}`
    }

    let streamError: string | null = null
    try {
      const res = await fetchImpl(
        resolveWorkspaceUrl(`/api/v1/keepers/${encodeURIComponent(params.keeper)}/github-login`),
        {
          method: 'POST',
          credentials: 'same-origin',
          headers,
          signal: controller.signal,
        },
      )
      if (!isEpochCurrent(startEpoch) || disposed) return
      if (!res.ok) {
        const errTxt = (await res.text().catch(() => `HTTP ${res.status}`)).trim() || `HTTP ${res.status}`
        emit({ phase: 'failed', message: `GitHub 로그인 시작 실패: ${errTxt}` })
        params.onSettled(false)
        return
      }
      if (!res.body) {
        emit({ phase: 'failed', message: 'GitHub 로그인 스트림 응답이 비어 있습니다.' })
        params.onSettled(false)
        return
      }

      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''

      const processFrame = (rawFrame: string) => {
        if (disposed) return
        let evName = 'message'
        const dataLines: string[] = []
        for (const line of rawFrame.split(/\r?\n/)) {
          if (line.startsWith('event:')) evName = line.slice(6).trim()
          else if (line.startsWith('data:')) dataLines.push(line.slice(5).trimStart())
        }
        if (dataLines.length === 0) return
        let parsed: unknown = null
        try {
          parsed = JSON.parse(dataLines.join('\n'))
        } catch {
          parsed = null
        }

        if (evName === 'error') {
          const msg = isRecord(parsed) && typeof parsed.message === 'string'
            ? parsed.message
            : 'GitHub 디바이스 로그인이 실패했습니다.'
          streamError = msg
          emit({ phase: 'failed', message: msg })
          return
        }

        if (evName === 'output' && isRecord(parsed) && typeof parsed.text === 'string') {
          const clean = stripAnsi(parsed.text)
          const nextTail = `${state.logTail}${clean}`.slice(-1200)
          const url = state.authorizeUrl ?? extractOAuthUrl(nextTail)
          const code = state.deviceCode ?? extractDeviceCode(nextTail)
          let popupBlocked = state.popupBlocked
          if (url && !openedUrl && typeof window !== 'undefined' && typeof window.open === 'function') {
            openedUrl = true
            try {
              const win = window.open(url, '_blank', 'noopener,noreferrer')
              popupBlocked = win === null
            } catch {
              popupBlocked = true
            }
          }
          emit({
            phase: 'awaiting_user',
            authorizeUrl: url,
            deviceCode: code,
            popupBlocked,
            logTail: nextTail,
            message: code
              ? `GitHub 디바이스 코드 ${code}를 인증 페이지에 입력하세요 (완료 시 자동 반영).`
              : 'GitHub 디바이스 인증을 진행하고 있습니다…',
          })
        }
      }

      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          buf += decoder.decode(value, { stream: true })
          const parts = buf.split(/\r?\n\r?\n/)
          buf = parts.pop() ?? ''
          for (const frame of parts) {
            if (frame.trim()) processFrame(frame)
          }
        }
        buf += decoder.decode()
        if (buf.trim()) processFrame(buf)
      } finally {
        reader.releaseLock()
      }

      if (disposed || !isEpochCurrent(startEpoch)) return
      if (streamError) {
        params.onSettled(false)
      } else {
        emit({ phase: 'completed', message: 'GitHub CLI 인증 완료 — 연결 도구를 자동 갱신합니다.' })
        params.onSettled(true)
      }
    } catch (e: unknown) {
      if (disposed || controller.signal.aborted) return
      const msg = e instanceof Error ? e.message : String(e)
      emit({ phase: 'failed', message: `GitHub 로그인 오류: ${msg}` })
      params.onSettled(false)
    } finally {
      unsubEpoch()
    }
  })()

  return {
    cancel: () => {
      disposed = true
      controller.abort('cancelled')
      unsubEpoch()
    },
  }
}

export function saveKeeperOAuthClient(params: {
  readonly provider: string
  readonly clientId: string
  readonly clientSecret?: string
  readonly scopes?: string
}): Promise<Result<Record<string, unknown>, ApiError>> {
  const body: Record<string, string> = {
    provider: params.provider.trim(),
    client_id: params.clientId.trim(),
  }
  if (params.clientSecret?.trim()) body.client_secret = params.clientSecret.trim()
  if (params.scopes?.trim()) body.scopes = params.scopes.trim()
  return apiMutate<Record<string, unknown>>('POST', '/api/v1/keepers/oauth/client', body)
}

export function disconnectKeeperOAuth(
  keeper: string,
  provider: string,
): Promise<Result<Record<string, unknown>, ApiError>> {
  return apiMutate<Record<string, unknown>>('POST', '/api/v1/keepers/oauth/disconnect', {
    keeper,
    provider,
  })
}

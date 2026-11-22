import { authHeaders, fetchControlPlane, get, postControlPlane } from './core'
import { ensureDevToken } from './dev-token'
import { isRecord } from '../lib/type-guards'
import type { Source } from './runtime-setup'

export type LoginInput = { kind: 'text'; text: string } | { kind: 'key'; key: 'enter' | 'up' | 'down' | 'tab' | 'eof' }
export type Authentication = 'authenticated' | 'login_completed' | 'credential_captured'
export interface LoginReceipt {
  login_id: string
  integration_id: string
  status: 'running' | 'complete' | 'failed' | 'cancelled' | 'interrupted'
  account?: 'linked' | 'keyring_host'
  account_ref?: string
  authentication?: Authentication
  invocation_verified: false
}
export type LoginEvent =
  | { event: 'started'; login_id: string; integration_id: string; account_ref?: string }
  | { event: 'output'; stream: 'stdout' | 'stderr'; text: string }
  /** The whole screen of a CLI that runs in a terminal; it replaces the one before. */
  | { event: 'screen'; text: string }
  | { event: 'input_ready' }
  | { event: 'complete'; source: Source; authentication: Authentication; keyringHost?: true }
  | { event: 'error'; login_id?: string; source?: Source }
const path = '/api/v1/setup/accounts/login'
const reference = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)
const keyringHost = (value: unknown): boolean => value === 'keyring_host'
const accountKind = (value: unknown): boolean => value === 'linked' || value === 'keyring_host'
const authentication = (value: unknown): value is Authentication => ['authenticated', 'login_completed', 'credential_captured'].includes(String(value))

export async function streamSetupLogin(source: Source, onEvent: (event: LoginEvent) => void, signal: AbortSignal): Promise<void> {
  await ensureDevToken()
  const response = await fetchControlPlane(path, { method: 'POST', headers: { ...authHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ integration_id: source.integration_id, ...(source.account_ref ? { account_ref: source.account_ref } : {}) }), signal })
  if (!response.ok || !response.body) throw new Error('Login stream unavailable')
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  let terminal = false
  let started = false
  try {
    while (true) {
      const { value, done } = await reader.read()
      buffer = (buffer + decoder.decode(value, { stream: !done })).replace(/\r\n/g, '\n')
      let boundary: number
      while ((boundary = buffer.indexOf('\n\n')) >= 0) {
        const frame = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 2)
        const lines = frame.split('\n')
        const event = lines.find(line => line.startsWith('event:'))?.slice(6).trim()
        const data = lines.filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n')
        if (!data) continue
        const payload: unknown = JSON.parse(data)
        if (!isRecord(payload) || terminal) throw new Error('Invalid login stream')
        if (event === 'started' && !started && reference(payload.login_id) && payload.integration_id === source.integration_id
          && (payload.account_ref === undefined || reference(payload.account_ref))
          && (payload.account === undefined || accountKind(payload.account))) {
          started = true
          onEvent({ event, login_id: payload.login_id, integration_id: source.integration_id, account_ref: payload.account_ref as string | undefined })
        } else if (event === 'output' && started && (payload.stream === 'stdout' || payload.stream === 'stderr') && typeof payload.text === 'string') {
          onEvent({ event, stream: payload.stream, text: payload.text })
        } else if (event === 'screen' && started && typeof payload.text === 'string') {
          onEvent({ event, text: payload.text })
        } else if (event === 'input_ready' && started) {
          onEvent({ event })
        } else if (event === 'complete' && started && payload.integration_id === source.integration_id
          && (reference(payload.account_ref) || (payload.account_ref === undefined && keyringHost(payload.account)))
          && authentication(payload.authentication) && payload.invocation_verified === false) {
          terminal = true
          const hasRef = reference(payload.account_ref)
          onEvent({
            event,
            source: hasRef
              ? { integration_id: source.integration_id, account_ref: payload.account_ref as string }
              : { integration_id: source.integration_id },
            authentication: payload.authentication,
            ...(!hasRef && keyringHost(payload.account) ? { keyringHost: true as const } : {}),
          })
        } else if (event === 'error') {
          if (payload.account_ref !== undefined && (!reference(payload.account_ref) || payload.integration_id !== source.integration_id)) throw new Error('Invalid login account')
          if (payload.login_id !== undefined && (!reference(payload.login_id) || payload.integration_id !== source.integration_id)) throw new Error('Invalid login identity')
          terminal = true; onEvent({ event, ...(reference(payload.login_id) ? { login_id: payload.login_id } : {}), source: reference(payload.account_ref)
            ? { integration_id: source.integration_id, account_ref: payload.account_ref } : undefined })
        } else throw new Error('Invalid login event')
      }
      if (done) break
    }
    if (!terminal || buffer.trim()) throw new Error('Login result not received')
  } finally {
    await reader.cancel().catch(() => undefined)
    reader.releaseLock()
  }
}
export async function sendLoginInput(id: string, input: LoginInput, signal?: AbortSignal): Promise<void> {
  if (!reference(id)) throw new Error('Invalid login identity')
  if (input.kind === 'text' && new TextEncoder().encode(input.text).length > 65536) throw new Error('Login input is too large')
  await postControlPlane(`${path}/${id}/input`, input, undefined, { signal })
}
export async function cancelSetupLogin(id: string): Promise<void> {
  if (!reference(id)) throw new Error('Invalid login identity')
  await postControlPlane(`${path}/${id}/cancel`, {})
}
export async function fetchLoginReceipt(id: string, integrationId: string, signal?: AbortSignal): Promise<LoginReceipt> {
  if (!reference(id)) throw new Error('Invalid login identity')
  await ensureDevToken()
  const value = await get<unknown>(`${path}/${id}`, { signal })
  if (!isRecord(value) || value.login_id !== id || value.integration_id !== integrationId || value.invocation_verified !== false
    || !['running', 'complete', 'failed', 'cancelled', 'interrupted'].includes(String(value.status))
    || (value.account_ref !== undefined && !reference(value.account_ref))
    || (value.account !== undefined && !accountKind(value.account))
    || (value.authentication !== undefined && !authentication(value.authentication))
    || (value.status === 'complete'
      && (!(reference(value.account_ref) || (value.account_ref === undefined && keyringHost(value.account)))
        || !authentication(value.authentication)))) throw new Error('Login state unavailable')
  return value as unknown as LoginReceipt
}

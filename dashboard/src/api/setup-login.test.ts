import { afterEach, expect, it, vi } from 'vitest'
import { streamSetupLogin, sendLoginInput, fetchLoginReceipt, type LoginEvent } from './setup-login'
import { get, postControlPlane } from './core'
vi.mock('./core', () => ({ authHeaders: () => ({ Authorization: 'Bearer fixture' }), get: vi.fn(), postControlPlane: vi.fn(),
  fetchControlPlane: (path: string, init: RequestInit) => fetch(path, init) }))
vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => {}) }))
afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks() })
const id = 'a'.repeat(64)
const account = 'b'.repeat(64)
const frame = (event: string, data: unknown) => `event: ${event}\r\ndata: ${JSON.stringify(data)}\r\n\r\n`
function serve(body: string, size = 7) {
  const bytes = new TextEncoder().encode(body)
  vi.stubGlobal('fetch', vi.fn(async () => new Response(new ReadableStream({ start(controller) {
    for (let offset = 0; offset < bytes.length; offset += size) controller.enqueue(bytes.slice(offset, offset + size))
    controller.close()
  } }), { status: 200 })))
}
it.each(['codex', 'claude', 'antigravity'])('streams fragmented %s login and keeps invocation unverified', async integration_id => {
  serve(frame('started', { login_id: id, integration_id, account_ref: account })
    + frame('output', { stream: 'stdout', text: '계정 안내 🌐' }) + frame('screen', { text: 'Select login method:\n> 1. Google OAuth' })
    + frame('input_ready', {})
    + frame('complete', { integration_id, account_ref: account, authentication: 'authenticated', invocation_verified: false }))
  const events: LoginEvent[] = []
  const signal = new AbortController().signal
  await streamSetupLogin({ integration_id, account_ref: account }, event => events.push(event), signal)
  expect(events.map(event => event.event)).toEqual(['started', 'output', 'screen', 'input_ready', 'complete'])
  expect(events[1]).toEqual({ event: 'output', stream: 'stdout', text: '계정 안내 🌐' })
  expect(events[2]).toEqual({ event: 'screen', text: 'Select login method:\n> 1. Google OAuth' })
  expect(events[4]).toEqual({ event: 'complete', source: { integration_id, account_ref: account }, authentication: 'authenticated' })
  expect(fetch).toHaveBeenCalledWith('/api/v1/setup/accounts/login', expect.objectContaining({ signal,
    body: JSON.stringify({ integration_id, account_ref: account }) }))
})
it('rejects lost completion and wrong-account responses, retaining no output in storage', async () => {
  serve(frame('started', { login_id: id, integration_id: 'codex' }))
  await expect(streamSetupLogin({ integration_id: 'codex' }, vi.fn(), new AbortController().signal)).rejects.toThrow('Login result not received')
  serve(frame('started', { login_id: id, integration_id: 'another-client' }))
  await expect(streamSetupLogin({ integration_id: 'codex' }, vi.fn(), new AbortController().signal)).rejects.toThrow('Invalid login event')
  // A terminal's bytes reach the client only as the screen the server drew.
  serve(frame('started', { login_id: id, integration_id: 'codex' }) + frame('output', { stream: 'terminal', text: 'x' }))
  await expect(streamSetupLogin({ integration_id: 'codex' }, vi.fn(), new AbortController().signal)).rejects.toThrow('Invalid login event')
})
it('returns recoverable account references on a failed login without exposing server errors', async () => {
  serve(frame('started', { login_id: id, integration_id: 'antigravity' })
    + frame('error', { integration_id: 'antigravity', account_ref: account, message: 'private-server-error' }))
  const events: LoginEvent[] = []
  await streamSetupLogin({ integration_id: 'antigravity' }, event => events.push(event), new AbortController().signal)
  expect(events[1]).toEqual({ event: 'error', source: { integration_id: 'antigravity', account_ref: account } })
  expect(JSON.stringify(events)).not.toContain('private-server-error')
})
it('sends codes only through the scoped input endpoint with cancellation', async () => {
  const signal = new AbortController().signal
  await sendLoginInput(id, { kind: 'text', text: 'fixture-code' }, signal)
  expect(postControlPlane).toHaveBeenCalledWith(`/api/v1/setup/accounts/login/${id}/input`,
    { kind: 'text', text: 'fixture-code' }, undefined, { signal })
  await expect(sendLoginInput('../other', { kind: 'key', key: 'eof' })).rejects.toThrow('Invalid login identity')
  await expect(sendLoginInput(id, { kind: 'text', text: '가'.repeat(23000) })).rejects.toThrow('too large')
})
it('accepts OS-keyring host login completion without account_ref for ACP clients', async () => {
  serve(frame('started', { login_id: id, integration_id: 'vibe_acp', account: 'keyring_host' })
    + frame('complete', { integration_id: 'vibe_acp', account: 'keyring_host', authentication: 'login_completed', invocation_verified: false }))
  const events: LoginEvent[] = []
  await streamSetupLogin({ integration_id: 'vibe_acp' }, event => events.push(event), new AbortController().signal)
  expect(events.map(event => event.event)).toEqual(['started', 'complete'])
  expect(events[1]).toEqual({ event: 'complete', source: { integration_id: 'vibe_acp' }, authentication: 'login_completed', keyringHost: true })
  vi.mocked(get).mockResolvedValue({ login_id: id, integration_id: 'vibe_acp', status: 'complete', account: 'keyring_host',
    authentication: 'login_completed', invocation_verified: false })
  const receipt = await fetchLoginReceipt(id, 'vibe_acp')
  expect(receipt.account).toBe('keyring_host')
  expect(receipt.account_ref).toBeUndefined()
})
it('validates durable receipt identity and proof before recovery', async () => {
  const signal = new AbortController().signal
  vi.mocked(get).mockResolvedValue({ login_id: id, integration_id: 'codex', status: 'complete', account_ref: account,
    authentication: 'login_completed', invocation_verified: false })
  expect((await fetchLoginReceipt(id, 'codex', signal)).account_ref).toBe(account)
  expect(get).toHaveBeenCalledWith(`/api/v1/setup/accounts/login/${id}`, { signal })
  vi.mocked(get).mockResolvedValue({ login_id: id, integration_id: 'codex', status: 'complete', invocation_verified: true })
  await expect(fetchLoginReceipt(id, 'codex')).rejects.toThrow('Login state unavailable')
})
it('retains a receipt identity when process launch fails before started', async () => {
  serve(frame('error', { login_id: id, integration_id: 'codex', account_ref: account, status: 'failed', invocation_verified: false }))
  const events: LoginEvent[] = []
  await streamSetupLogin({ integration_id: 'codex' }, event => events.push(event), new AbortController().signal)
  expect(events).toEqual([{ event: 'error', login_id: id, source: { integration_id: 'codex', account_ref: account } }])
})

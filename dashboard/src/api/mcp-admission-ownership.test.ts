import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { callMcpTool, resetMcpClientState } from './mcp'
import { clearStoredToken, getStoredToken, setStoredToken, subscribeStoredTokenChanges } from './core'
import { devTokenBootstrapStatus, ensureDevToken, resetDevTokenBootstrap } from './dev-token'
vi.mock('../components/common/toast', () => ({ showActionToast: vi.fn() }))
vi.mock('./tool-host-failure', () => ({ reportToolHostFailure: vi.fn() }))
const fetchMock = vi.fn()
const toolResponse = () => new Response(`data: ${JSON.stringify({ result: { content: [{ type: 'text', text: 'ok' }] } })}\n`, { status: 200 })
const bootstrapResponse = () => new Response(JSON.stringify({ token: 'synthetic-bootstrap', actor: 'dashboard', role: 'admin' }), { status: 200 })
beforeEach(() => { clearStoredToken(); resetMcpClientState(); fetchMock.mockReset(); vi.stubGlobal('fetch', fetchMock) })
afterEach(() => { clearStoredToken(); resetMcpClientState(); vi.unstubAllGlobals() })
it('does not submit an admitted tool under a replacement manual credential', async () => {
  setStoredToken('synthetic-manual-a')
  fetchMock.mockResolvedValue(toolResponse())
  const request = callMcpTool('masc_broadcast', { message: 'previous session body' })
  setStoredToken('synthetic-manual-b')
  const outcome = await Promise.allSettled([request])
  expect(fetchMock).not.toHaveBeenCalled()
  expect(outcome[0].status).toBe('rejected')
})
it('does not submit a waiting bootstrap request under a newly installed manual credential', async () => {
  let resolve!: (response: Response) => void
  fetchMock.mockReturnValueOnce(new Promise(done => { resolve = done })).mockResolvedValue(toolResponse())
  const request = callMcpTool('masc_broadcast', { message: 'pre-bootstrap body' })
  expect(fetchMock).toHaveBeenCalledTimes(1)
  setStoredToken('synthetic-manual-b')
  resolve(bootstrapResponse())
  const outcome = await Promise.allSettled([request])
  expect(fetchMock).toHaveBeenCalledTimes(1)
  expect(getStoredToken()).toBe('synthetic-manual-b')
  expect(outcome[0].status).toBe('rejected')
})
it('does not let a superseded bootstrap overwrite a later URL credential', async () => {
  let resolve!: (response: Response) => void
  fetchMock.mockReturnValueOnce(new Promise(done => { resolve = done }))
  const bootstrap = ensureDevToken()
  setStoredToken('synthetic-url-b', { source: 'url' })
  resolve(bootstrapResponse())
  await bootstrap
  expect(getStoredToken()).toBe('synthetic-url-b')
})
it('admits its own loopback bootstrap and reuses the bound credential', async () => {
  fetchMock.mockResolvedValueOnce(bootstrapResponse()).mockImplementation(async () => toolResponse())
  await expect(callMcpTool('masc_broadcast', { message: 'own bootstrap body' })).resolves.toBe('ok')
  await expect(callMcpTool('masc_broadcast', { message: 'next bound body' })).resolves.toBe('ok')
  expect(fetchMock).toHaveBeenCalledTimes(3)
  const init = fetchMock.mock.calls[1]?.[1] as RequestInit
  expect(init).toBeDefined()
  const headers = new Headers(init.headers)
  expect(headers.get('Authorization')).toBe('Bearer synthetic-bootstrap')
})

it('does not install a bootstrap whose response body completes after a credential change', async () => {
  let controller!: ReadableStreamDefaultController<Uint8Array>
  const body = new ReadableStream<Uint8Array>({ start(value) { controller = value } })
  fetchMock.mockResolvedValue(new Response(body, { status: 200 }))
  const bootstrap = ensureDevToken()
  await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
  setStoredToken('synthetic-url-after-headers', { source: 'url' })
  controller.enqueue(new TextEncoder().encode(JSON.stringify({ token: 'synthetic-old-bootstrap', actor: 'dashboard', role: 'admin' })))
  controller.close()
  await expect(bootstrap).resolves.toEqual({ kind: 'superseded' })
  expect(getStoredToken()).toBe('synthetic-url-after-headers')
})
it.each(['response', 'network failure'] as const)('does not let an obsolete bootstrap %s retire its replacement', async (completion) => {
  let resolveOld!: (response: Response) => void
  let rejectOld!: (error: Error) => void
  let resolveNew!: (response: Response) => void
  fetchMock.mockReturnValueOnce(new Promise((done, fail) => { resolveOld = done; rejectOld = fail }))
    .mockReturnValueOnce(new Promise(done => { resolveNew = done }))
  const old = ensureDevToken()
  resetDevTokenBootstrap()
  const current = ensureDevToken()
  if (completion === 'response') resolveOld(new Response('', { status: 404 }))
  else rejectOld(new Error('obsolete bootstrap failure'))
  await expect(old).resolves.toEqual({ kind: 'superseded' })
  expect(devTokenBootstrapStatus.value).toBe('fetching')
  const shared = ensureDevToken()
  expect(fetchMock).toHaveBeenCalledTimes(2)
  resolveNew(bootstrapResponse())
  const result = await current
  await expect(shared).resolves.toEqual(result)
  expect(result.kind).toBe('bound')
  expect(getStoredToken()).toBe('synthetic-bootstrap')
})

it.each(['install', 'clear'] as const)('does not adopt a credential installed by a synchronous listener during bootstrap %s', async (publication) => {
  if (publication === 'clear') setStoredToken('synthetic-dev-before-clear', { source: 'dev', actor: 'dashboard', role: 'admin' })
  const unsubscribe = subscribeStoredTokenChanges(change => {
    if ((publication === 'install' && change.meta?.source === 'dev') || (publication === 'clear' && change.token === null)) {
      setStoredToken('synthetic-listener-owner')
    }
  })
  try {
    fetchMock.mockResolvedValueOnce(publication === 'install' ? bootstrapResponse() : new Response('', { status: 404 }))
      .mockImplementation(async () => toolResponse())
    const outcome = await Promise.allSettled([callMcpTool('masc_broadcast', { message: 'bootstrap owner body' })])
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getStoredToken()).toBe('synthetic-listener-owner')
    expect(outcome[0].status).toBe('rejected')
  } finally {
    unsubscribe()
  }
})

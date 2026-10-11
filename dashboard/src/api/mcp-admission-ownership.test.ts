import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { callMcpTool, listAllMcpTools, resetMcpClientState } from './mcp'
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
  let controller!: ReadableStreamDefaultController<Uint8Array<ArrayBuffer>>
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ start(value) { controller = value } })
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

it('does not retry an old tool under a replacement credential during authentication recovery', async () => {
  setStoredToken('synthetic-dev-a', { source: 'dev', actor: 'dashboard', role: 'admin' })
  let completeRecovery!: (response: Response) => void
  let bootstrapCalls = 0
  let toolCalls = 0
  fetchMock.mockImplementation(async (path: string) => {
    if (path === '/api/v1/dashboard/dev-token') {
      bootstrapCalls += 1
      if (bootstrapCalls === 2) return new Promise<Response>(done => { completeRecovery = done })
      return new Response(JSON.stringify({ token: bootstrapCalls === 1 ? 'synthetic-dev-a' : 'synthetic-dev-b', actor: 'dashboard', role: 'admin' }))
    }
    toolCalls += 1
    return toolCalls === 1
      ? new Response(`data: ${JSON.stringify({ result: { isError: true, content: [{ type: 'text', text: 'credential refused' }], structuredContent: { auth_error_code: 'actor_mismatch' } } })}\n`)
      : toolResponse()
  })
  const request = callMcpTool('masc_broadcast', { message: 'old request body' })
  await vi.waitFor(() => expect(bootstrapCalls).toBe(2))
  setStoredToken('synthetic-dev-b', { source: 'dev', actor: 'dashboard', role: 'admin' })
  completeRecovery(bootstrapResponse())
  const outcome = await Promise.allSettled([request])
  expect(toolCalls).toBe(1)
  expect(getStoredToken()).toBe('synthetic-dev-b')
  expect(outcome[0].status).toBe('rejected')
})

it('retries with its own refreshed credential and preserves the original tool input', async () => {
  setStoredToken('synthetic-dev-a', { source: 'dev', actor: 'dashboard', role: 'admin' })
  let bootstrapCalls = 0
  let toolCalls = 0
  fetchMock.mockImplementation(async (path: string) => {
    if (path === '/api/v1/dashboard/dev-token') {
      bootstrapCalls += 1
      return new Response(JSON.stringify({ token: bootstrapCalls === 1 ? 'synthetic-dev-a' : 'synthetic-owned-refresh', actor: 'dashboard', role: 'admin' }))
    }
    toolCalls += 1
    return toolCalls === 1
      ? new Response(`data: ${JSON.stringify({ result: { isError: true, content: [{ type: 'text', text: 'credential refused' }], structuredContent: { auth_error_code: 'actor_mismatch' } } })}\n`)
      : toolResponse()
  })
  await expect(callMcpTool('masc_broadcast', { message: 'owned retry input' })).resolves.toBe('ok')
  const requests = fetchMock.mock.calls.filter(([path]) => path === '/mcp')
  expect(requests).toHaveLength(2)
  expect(requests.map(([, init]) => new Headers((init as RequestInit).headers).get('Authorization')))
    .toEqual(['Bearer synthetic-dev-a', 'Bearer synthetic-owned-refresh'])
  expect(requests.map(([, init]) => JSON.parse((init as RequestInit).body as string).params.arguments.message))
    .toEqual(['owned retry input', 'owned retry input'])
})

it('rejects a previous credential HTTP error body before recovery or publication', async () => {
  setStoredToken('synthetic-error-owner-a')
  let controller!: ReadableStreamDefaultController<Uint8Array<ArrayBuffer>>
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ start(value) { controller = value } })
  const response = new Response(body, { status: 401 })
  const text = response.text.bind(response)
  let reading = false
  vi.spyOn(response, 'text').mockImplementation(() => { reading = true; return text() })
  vi.spyOn(response, 'body', 'get').mockImplementation(() => { reading = true; return body })
  fetchMock.mockResolvedValue(response)
  const request = callMcpTool('masc_broadcast', { message: 'previous error owner body' })
  await vi.waitFor(() => expect(reading).toBe(true))
  setStoredToken('synthetic-error-owner-b')
  // Cancellation may close the stream before a late server chunk arrives.
  try {
    controller.enqueue(new TextEncoder().encode(JSON.stringify({ error: 'old credential failure', auth_error_code: 'token_expired' })))
    controller.close()
  } catch { /* The superseded body was already cancelled. */ }
  const outcome = await Promise.allSettled([request])
  expect(fetchMock).toHaveBeenCalledTimes(1)
  expect(outcome[0].status).toBe('rejected')
  if (outcome[0].status === 'rejected') expect(outcome[0].reason.message).toBe('MCP authentication changed during request')
})

it('cancels a stalled authentication error body when its credential owner changes', async () => {
  setStoredToken('synthetic-stalled-owner-a')
  let controller!: ReadableStreamDefaultController<Uint8Array<ArrayBuffer>>
  const cancel = vi.fn()
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ start(value) { controller = value }, cancel })
  const response = new Response(body, { status: 401 })
  const text = response.text.bind(response)
  let reading = false
  vi.spyOn(response, 'text').mockImplementation(() => { reading = true; return text() })
  vi.spyOn(response, 'body', 'get').mockImplementation(() => { reading = true; return body })
  fetchMock.mockResolvedValue(response)
  const pending = callMcpTool('masc_broadcast', { message: 'stalled old body' }).catch(error => error)
  await vi.waitFor(() => expect(reading).toBe(true))
  setStoredToken('synthetic-stalled-owner-b')
  try {
    await vi.waitFor(() => expect(cancel).toHaveBeenCalledTimes(1))
    expect((await pending).message).toBe('MCP authentication changed during request')
  } finally {
    if (cancel.mock.calls.length === 0) controller.close()
    await pending
  }
})

it('disposes an acquired response whose credential changed before headers arrived', async () => {
  setStoredToken('synthetic-header-owner-a')
  let resolve!: (response: Response) => void
  const cancel = vi.fn()
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ cancel })
  fetchMock.mockReturnValue(new Promise<Response>(done => { resolve = done }))
  const pending = callMcpTool('masc_broadcast', { message: 'old header owner' }).catch(error => error)
  await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
  setStoredToken('synthetic-header-owner-b')
  resolve(new Response(body, { status: 500 }))
  expect((await pending).message).toBe('MCP authentication changed during request')
  try {
    expect(cancel).toHaveBeenCalledTimes(1)
  } finally {
    if (cancel.mock.calls.length === 0) await body.cancel()
  }
})

it('cancels a stalled successful response when its credential owner changes', async () => {
  setStoredToken('synthetic-success-owner-a')
  let controller!: ReadableStreamDefaultController<Uint8Array<ArrayBuffer>>
  const cancel = vi.fn()
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ start(value) { controller = value }, cancel })
  const response = new Response(body)
  let reading = false
  const originalText = response.text.bind(response)
  vi.spyOn(response, 'text').mockImplementation(() => { reading = true; return originalText() })
  vi.spyOn(response, 'body', 'get').mockImplementation(() => { reading = true; return body })
  fetchMock.mockResolvedValue(response)
  const pending = callMcpTool('masc_broadcast', { message: 'stalled success body' }).catch(error => error)
  await vi.waitFor(() => expect(reading).toBe(true))
  setStoredToken('synthetic-success-owner-b')
  try {
    await vi.waitFor(() => expect(cancel).toHaveBeenCalledTimes(1))
    expect((await pending).message).toBe('MCP authentication changed during request')
  } finally {
    if (cancel.mock.calls.length === 0) controller.close()
    await pending
  }
})

it('disposes a forbidden response without reading its body', async () => {
  setStoredToken('synthetic-forbidden-owner')
  const cancel = vi.fn()
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ cancel })
  fetchMock.mockResolvedValue(new Response(body, { status: 403 }))
  await expect(callMcpTool('masc_broadcast', { message: 'forbidden input' })).rejects.toThrow()
  try {
    expect(cancel).toHaveBeenCalledTimes(1)
  } finally {
    if (cancel.mock.calls.length === 0) await body.cancel()
  }
})

it('aborts a request waiting for headers when its credential owner changes', async () => {
  setStoredToken('synthetic-waiting-owner-a')
  let signal!: AbortSignal
  let finish!: (response: Response) => void
  fetchMock.mockImplementation((_path: string, init: RequestInit) => new Promise<Response>((resolve, reject) => {
    finish = resolve
    signal = init.signal!
    signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
  }))
  const pending = callMcpTool('masc_broadcast', { message: 'waiting old request' }).catch(error => error)
  await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
  setStoredToken('synthetic-waiting-owner-b')
  try {
    expect(signal.aborted).toBe(true)
    expect((await pending).message).toBe('MCP authentication changed during request')
  } finally {
    if (!signal.aborted) finish(toolResponse())
    await pending
  }
})

it.each([true, false])('rejects credential replacement after page decode (has next page: %s)', async (hasNextPage) => {
  setStoredToken('synthetic-page-owner-a')
  const first = JSON.stringify({ result: { tools: [{ name: 'owner-a-tool', inputSchema: {} }], ...(hasNextPage ? { nextCursor: 'owner-a-cursor' } : {}) } })
  const second = JSON.stringify({ result: { tools: [{ name: 'owner-b-tool', inputSchema: {} }] } })
  fetchMock.mockResolvedValueOnce(new Response(first)).mockResolvedValueOnce(new Response(second))
  const parse = JSON.parse
  // Schedule an external credential change after the first actual page decode,
  // before the aggregate continues to its next page admission.
  const decode = vi.spyOn(JSON, 'parse').mockImplementation((text, reviver) => {
    const result = parse(text, reviver)
    if (text === first) queueMicrotask(() => setStoredToken('synthetic-page-owner-b'))
    return result
  })
  try {
    const outcome = await Promise.allSettled([listAllMcpTools()])
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(outcome[0].status).toBe('rejected')
    if (outcome[0].status === 'rejected') expect(outcome[0].reason.message).toBe('MCP authentication changed during request')
  } finally {
    decode.mockRestore()
  }
})

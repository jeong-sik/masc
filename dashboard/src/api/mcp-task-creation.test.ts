// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, currentDashboardActor, currentStoredTokenRevision, getStoredToken, setStoredToken } from './core'
import { callMcpTaskCreationAtIdentity, callMcpToolAtIdentity, mcpCallFailureDisposition, resetMcpClientState } from './mcp'
import { resetDashboardSessionActorForTests } from '../lib/dashboard-session-actor'
import { DEFAULT_MCP_TIMEOUT_MS } from '../config/constants'

vi.mock('./tool-host-failure', () => ({ reportToolHostFailure: vi.fn().mockResolvedValue(undefined) }))
vi.mock('../components/common/toast', () => ({ showActionToast: vi.fn(), showToast: vi.fn() }))

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(done => { resolve = done })
  return { promise, resolve }
}

const args = () => ({ title: 'private title', description: 'private description', goal_id: 'goal-a',
  creation_request_id: 'create-a', expected_workspace: { base_path: '/a', masc_root: '/a/.masc' } })
const identity = () => ({ revision: currentStoredTokenRevision(), actor: currentDashboardActor() })
const successText = (changes: Record<string, unknown> = {}) => JSON.stringify({ ok: true, task_id: 'task-1',
  creation_request_id: 'create-a', goal_id: 'goal-a', title: 'private title', description: 'private description', ...changes })
const responseBody = (id: string, text = successText()) => JSON.stringify({ jsonrpc: '2.0', id,
  result: { content: [{ type: 'text', text }] } })

beforeEach(() => {
  clearStoredToken()
  resetDashboardSessionActorForTests()
  setStoredToken('token-a', { source: 'manual' })
  resetMcpClientState()
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
  clearStoredToken()
  resetDashboardSessionActorForTests()
  resetMcpClientState()
})

it.each(['json', 'sse'] as const)('retains only a validated %s Task result after its body owner retires', async format => {
  const started = deferred<void>()
  const body = deferred<string>()
  let rpcId = ''
  const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
    const request = JSON.parse(String(init.body))
    rpcId = request.id
    expect(request.params.name).toBe('masc_add_task')
    expect(request.params.arguments.expected_workspace).toEqual({ base_path: '/a', masc_root: '/a/.masc' })
    const response = new Response('', { status: 200 })
    response.text = () => { started.resolve(); return body.promise }
    return response
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  const raw = responseBody(rpcId)
  body.resolve(format === 'sse' ? `data: ${raw}\n\n` : raw)

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(retained).toHaveBeenCalledExactlyOnceWith({ kind: 'created', taskId: 'task-1' })
  expect(JSON.stringify(retained.mock.calls)).not.toContain('private')
  expect(fetchMock).toHaveBeenCalledOnce()
  expect(getStoredToken()).toBe('token-b')
})

it('reads the original successful response when the token changes before its headers arrive', async () => {
  const started = deferred<void>()
  const response = deferred<Response>()
  let rpcId = ''
  const fetchMock = vi.fn((_url: string, init: RequestInit) => {
    rpcId = JSON.parse(String(init.body)).id
    started.resolve()
    return response.promise
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  response.resolve(new Response(responseBody(rpcId), { status: 200 }))

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(retained).toHaveBeenCalledExactlyOnceWith({ kind: 'created', taskId: 'task-1' })
  expect(fetchMock).toHaveBeenCalledOnce()
})

it('retains a goalless Task only when the response also has no Goal', async () => {
  const started = deferred<void>()
  const response = deferred<Response>()
  let rpcId = ''
  const fetchMock = vi.fn((_url: string, init: RequestInit) => {
    rpcId = JSON.parse(String(init.body)).id
    started.resolve()
    return response.promise
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const { goal_id: _goal, ...goalless } = args()
  const pending = callMcpTaskCreationAtIdentity(goalless, identity(), () => true, undefined, undefined, retained)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  response.resolve(new Response(responseBody(rpcId, successText({ goal_id: null })), { status: 200 }))

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(retained).toHaveBeenCalledExactlyOnceWith({ kind: 'created', taskId: 'task-1' })
  expect(fetchMock).toHaveBeenCalledOnce()
})

it('keeps the ordinary scoped result when the Task credential stays current', async () => {
  const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
    const request = JSON.parse(String(init.body))
    return new Response(responseBody(request.id), { status: 200 })
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  await expect(callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained))
    .resolves.toBe(successText())
  expect(retained).not.toHaveBeenCalled()
  expect(fetchMock).toHaveBeenCalledOnce()
})

it.each([
  ['duplicate RPC id', (id: string) => responseBody(id).replace(`"id":"${id}"`, `"id":"other","id":"${id}"`)],
  ['duplicate error flag', (id: string) => responseBody(id).replace('"result":{', '"result":{"isError":true,"isError":false,')],
  ['non-text content', (id: string) => JSON.stringify({ id, result: { content: [{ type: 'image', text: successText() }] } })],
] as const)('does not accept a current %s response as Task success', async (_name, makeBody) => {
  const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
    const request = JSON.parse(String(init.body))
    return new Response(makeBody(request.id), { status: 200 })
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const error = await callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
    .catch((caught: unknown) => caught)
  expect(error).toBeInstanceOf(Error)
  expect(mcpCallFailureDisposition(error)).toBe('outcome_unknown')
  expect(retained).not.toHaveBeenCalled()
  expect(fetchMock).toHaveBeenCalledOnce()
})

it.each([
  ['wrong RPC id', (id: string): string => responseBody(`${id}-other`)],
  ['duplicate RPC id', (id: string) => responseBody(id).replace(`"id":"${id}"`, `"id":"other","id":"${id}"`)],
  ['wrong creation id', (id: string) => responseBody(id, successText({ creation_request_id: 'other' }))],
  ['duplicate creation id', (id: string) => responseBody(id, successText().replace('"creation_request_id":"create-a"',
    '"creation_request_id":"other","creation_request_id":"create-a"'))],
  ['wrong goal', (id: string) => responseBody(id, successText({ goal_id: 'goal-b' }))],
  ['duplicate goal', (id: string) => responseBody(id, successText().replace('"goal_id":"goal-a"', '"goal_id":"other","goal_id":"goal-a"'))],
  ['blank task', (id: string) => responseBody(id, successText({ task_id: ' ' }))],
  ['duplicate task', (id: string) => responseBody(id, successText().replace('"task_id":"task-1"', '"task_id":"other","task_id":"task-1"'))],
  ['tool error', (id: string) => JSON.stringify({ id, result: { isError: true, content: [{ type: 'text', text: successText() }] } })],
  ['RPC error', (id: string) => JSON.stringify({ id, error: { message: 'refused' } })],
  ['wrong content type', (id: string) => JSON.stringify({ id, result: { content: [{ type: 'image', text: successText() }] } })],
  ['partial body', (_id: string): string => '{"id":'],
] as const)('does not retain a stale %s response', async (_name, makeBody) => {
  const started = deferred<void>()
  const response = deferred<Response>()
  let rpcId = ''
  const fetchMock = vi.fn((_url: string, init: RequestInit) => {
    rpcId = JSON.parse(String(init.body)).id
    started.resolve()
    return response.promise
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  response.resolve(new Response(makeBody(rpcId), { status: 200 }))

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(retained).not.toHaveBeenCalled()
  expect(fetchMock).toHaveBeenCalledOnce()
})

it.each([401, 403])('does not read or recover a stale HTTP %s response', async status => {
  const started = deferred<void>()
  const response = deferred<Response>()
  const fetchMock = vi.fn(() => { started.resolve(); return response.promise })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  const denied = new Response('private error', { status })
  const read = vi.spyOn(denied, 'text')
  response.resolve(denied)

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(read).not.toHaveBeenCalled()
  expect(retained).not.toHaveBeenCalled()
  expect(fetchMock).toHaveBeenCalledOnce()
  expect(getStoredToken()).toBe('token-b')
})

it('bounds a stalled Task body and never replays after its credential changes', async () => {
  vi.useFakeTimers()
  const started = deferred<void>()
  const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
    const response = new Response('', { status: 200 })
    response.text = () => {
      started.resolve()
      return new Promise((_resolve, reject) => {
        init.signal!.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      })
    }
    return response
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
    .catch((error: unknown) => error)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  await vi.advanceTimersByTimeAsync(DEFAULT_MCP_TIMEOUT_MS)
  const error = await pending

  expect(mcpCallFailureDisposition(error)).toBe('outcome_unknown')
  expect(retained).not.toHaveBeenCalled()
  expect(fetchMock).toHaveBeenCalledOnce()
  expect(getStoredToken()).toBe('token-b')
})

it('does not let a receipt callback replace the stale outcome', async () => {
  const started = deferred<void>()
  const response = deferred<Response>()
  let rpcId = ''
  const fetchMock = vi.fn((_url: string, init: RequestInit) => {
    rpcId = JSON.parse(String(init.body)).id
    started.resolve()
    return response.promise
  })
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn(() => { throw new Error('local receipt failed') })
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => true, undefined, undefined, retained)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  response.resolve(new Response(responseBody(rpcId), { status: 200 }))

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(retained).toHaveBeenCalledOnce()
  expect(fetchMock).toHaveBeenCalledOnce()
})

it('leaves the generic scoped Task call guarded at response headers', async () => {
  const started = deferred<void>()
  const response = deferred<Response>()
  const fetchMock = vi.fn(() => { started.resolve(); return response.promise })
  vi.stubGlobal('fetch', fetchMock)
  const pending = callMcpToolAtIdentity('masc_add_task', args(), identity(), () => true)
  await started.promise
  setStoredToken('token-b', { source: 'manual' })
  const result = new Response('private body', { status: 200 })
  const read = vi.spyOn(result, 'text')
  response.resolve(result)

  await expect(pending).rejects.toThrow('MCP authentication changed during request')
  expect(read).not.toHaveBeenCalled()
  expect(fetchMock).toHaveBeenCalledOnce()
})

it('rejects a Task without its request and workspace before sending', async () => {
  const fetchMock = vi.fn()
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  const error: unknown = await callMcpTaskCreationAtIdentity({ title: 'test' }, identity(), () => true,
    undefined, undefined, retained).catch(error => error)
  expect(mcpCallFailureDisposition(error)).toBe('known_pre_effect')
  expect(fetchMock).not.toHaveBeenCalled()
  expect(retained).not.toHaveBeenCalled()
})

it('refuses a Task before dispatch when its scoped owner retires', async () => {
  const fetchMock = vi.fn()
  vi.stubGlobal('fetch', fetchMock)
  const retained = vi.fn()
  let current = true
  const pending = callMcpTaskCreationAtIdentity(args(), identity(), () => current, undefined, undefined, retained)
    .catch((error: unknown) => error)
  current = false
  const error = await pending
  expect(mcpCallFailureDisposition(error)).toBe('known_pre_effect')
  expect(fetchMock).not.toHaveBeenCalled()
  expect(retained).not.toHaveBeenCalled()
})

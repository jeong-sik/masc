// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, currentStoredTokenRevision, getStoredToken, setStoredToken } from '../../api/core'
import { resetDevTokenBootstrap } from '../../api/dev-token'
import { resetMcpClientState } from '../../api/mcp'
import { DEFAULT_MCP_TIMEOUT_MS } from '../../config/constants'
import { managedDashboardUnverified, resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import { _testResetTaskCreateState, beginSeparateTaskDraft, createTask, recheckTaskCreation,
  taskCreateReceipts, taskCreating } from './task-manage-state'

const mocks = vi.hoisted(() => ({
  authority: { peek: vi.fn() },
  workspaceRevision: { peek: vi.fn() },
  executionError: { peek: vi.fn() },
  lastGoalsRefreshAt: { peek: vi.fn() },
  tasks: { peek: vi.fn() },
  refreshExecution: vi.fn(),
  refreshGoals: vi.fn(),
  refreshShell: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('../../store', () => ({ executionWorkspaceAuthority: mocks.authority, executionWorkspaceRevision: mocks.workspaceRevision,
  executionError: mocks.executionError, tasks: mocks.tasks, lastGoalsRefreshAt: mocks.lastGoalsRefreshAt,
  refreshExecution: mocks.refreshExecution, refreshGoals: mocks.refreshGoals, refreshShell: mocks.refreshShell }))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../../api/tool-host-failure', () => ({ reportToolHostFailure: async () => {} }))

const authority = { epoch: 'epoch-a', workspaceRoot: '/a', connectionGeneration: 1 }

function health(): Response {
  return new Response(JSON.stringify({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } }),
    { status: 200, headers: { 'Content-Type': 'application/json' } })
}

function stalledResponse(status: number, started: () => void, signal: AbortSignal): Response {
  const body = () => {
    started()
    return new Promise<never>((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
    })
  }
  const response = { ok: status === 200, status, statusText: '', headers: new Headers(), text: body,
    json: body, clone: () => response } as unknown as Response
  return response
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.resetAllMocks()
  clearStoredToken()
  resetDashboardSessionActorForTests()
  resetDevTokenBootstrap()
  resetMcpClientState()
  _testResetTaskCreateState()
  mocks.authority.peek.mockReturnValue(authority)
  mocks.workspaceRevision.peek.mockReturnValue(1)
  mocks.executionError.peek.mockReturnValue(null)
  mocks.tasks.peek.mockReturnValue([{ id: 'task-1' }])
  mocks.refreshExecution.mockResolvedValue(undefined)
  mocks.refreshGoals.mockResolvedValue(undefined)
  mocks.refreshShell.mockResolvedValue(true)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
  clearStoredToken()
  resetDashboardSessionActorForTests()
  resetDevTokenBootstrap()
  resetMcpClientState()
})

it('sends a goalless Task once with the observed workspace and identity', async () => {
  setStoredToken('manual-token', { source: 'manual' })
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    if (url === '/health?full=1') return health()
    expect(url).toBe('/mcp')
    const request = JSON.parse(String(init.body))
    expect(request.params.name).toBe('masc_add_task')
    expect(request.params.arguments).toMatchObject({ title: 't', expected_workspace: { base_path: '/a', masc_root: '/a/.masc' } })
    expect(request.params.arguments).not.toHaveProperty('goal_id')
    const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
      goal_id: null, task_id: 'task-1' })
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } }),
      { status: 200, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  expect(await createTask({ title: 't', description: '' })).toBe(true)
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
})

it.each([401, 403])('does not authorize restored evidence when the current credential receives HTTP %i', async status => {
  setStoredToken('actor-a-token', { source: 'manual' })
  let creating = true
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    if (url === '/health?full=1') return health()
    expect(url).toBe('/mcp')
    const request = JSON.parse(String(init.body))
    if (!creating) return new Response('denied', { status })
    expect(request.params.name).toBe('masc_add_task')
    const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
      goal_id: null, task_id: 'task-private' })
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } }),
      { status: 200, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  expect(await createTask({ title: 't', description: '' }, undefined, { finish: () => false })).toBe(true)
  const requestId = taskCreateReceipts.attempts.peek()[0]?.requestId
  if (!requestId) throw new Error('Missing Task creation attempt')
  creating = false
  setStoredToken('actor-b-token', { source: 'manual' })
  _testResetTaskCreateState({ preserveStorage: true })
  await recheckTaskCreation(requestId)
  expect(taskCreateReceipts.attempts.peek()[0]).toMatchObject({ originalCurrent: false, latestReadCurrent: false,
    latestReadFailureCurrent: true, original: { kind: 'created', taskId: 'task-private' },
    reads: [{ kind: 'error', reason: 'lookup_failed' }] })
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(2)
})

it('does not present a late response as success after the workspace changes', async () => {
  setStoredToken('manual-token', { source: 'manual' })
  let finishBody!: (body: string) => void
  let markStarted!: () => void
  const started = new Promise<void>(resolve => { markStarted = resolve })
  let requestId = ''
  let creationRequestId = ''
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    if (url === '/health?full=1') return health()
    expect(url).toBe('/mcp')
    const request = JSON.parse(String(init.body))
    requestId = request.id
    creationRequestId = request.params.arguments.creation_request_id
    const response = new Response('', { status: 200 })
    response.text = () => { markStarted(); return new Promise(resolve => { finishBody = resolve }) }
    return response
  })
  vi.stubGlobal('fetch', fetchMock)
  const finish = vi.fn(() => true)
  const pending = createTask({ title: 't', description: '' }, undefined, { finish })
  await started
  mocks.authority.peek.mockReturnValue({ epoch: 'epoch-b', workspaceRoot: '/b', connectionGeneration: 1 })
  const text = JSON.stringify({ ok: true, creation_request_id: creationRequestId, goal_id: null, task_id: 'task-1' })
  finishBody(JSON.stringify({ jsonrpc: '2.0', id: requestId, result: { content: [{ type: 'text', text }] } }))
  expect(await pending).toBe(true)
  expect(finish).not.toHaveBeenCalled()
  expect(mocks.showToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')
  expect(mocks.refreshExecution).not.toHaveBeenCalled()
  expect(mocks.refreshGoals).not.toHaveBeenCalled()
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
})

it('retains a validated stale success only on its original reservation after a token change', async () => {
  setStoredToken('actor-a-token', { source: 'manual' })
  let finishOld!: (body: string) => void
  let markStarted!: () => void
  const started = new Promise<void>(resolve => { markStarted = resolve })
  let oldRpcId = ''
  let oldCreationId = ''
  let postCount = 0
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    if (url === '/health?full=1') return health()
    expect(url).toBe('/mcp')
    const request = JSON.parse(String(init.body))
    expect(request.params.name).toBe('masc_add_task')
    postCount++
    if (postCount === 1) {
      oldRpcId = request.id
      oldCreationId = request.params.arguments.creation_request_id
      const response = new Response('', { status: 200 })
      response.text = () => { markStarted(); return new Promise(resolve => { finishOld = resolve }) }
      return response
    }
    const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
      goal_id: null, task_id: 'task-b' })
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } }),
      { status: 200, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  const oldRequest = createTask({ title: 'old', description: '' })
  await started
  setStoredToken('actor-b-token', { source: 'manual' })
  beginSeparateTaskDraft()
  expect(await createTask({ title: 'new', description: '' })).toBe(true)
  const newAttempt = taskCreateReceipts.attempts.peek().find(item => item.requestId !== oldCreationId)
  expect(newAttempt?.original).toEqual({ kind: 'created', taskId: 'task-b' })
  const text = JSON.stringify({ ok: true, creation_request_id: oldCreationId, goal_id: null, task_id: 'task-a' })
  finishOld(JSON.stringify({ jsonrpc: '2.0', id: oldRpcId, result: { content: [{ type: 'text', text }] } }))
  expect(await oldRequest).toBe(false)
  expect(taskCreateReceipts.attempts.peek().find(item => item.requestId === oldCreationId)).toMatchObject({
    original: { kind: 'created', taskId: 'task-a' }, originalCurrent: false, presented: false,
  })
  expect(taskCreateReceipts.attempts.peek().find(item => item.requestId === newAttempt?.requestId)?.original)
    .toEqual({ kind: 'created', taskId: 'task-b' })
  expect(postCount).toBe(2)
  _testResetTaskCreateState({ preserveStorage: true })
  expect(taskCreateReceipts.attempts.peek().find(item => item.requestId === oldCreationId)?.original)
    .toEqual({ kind: 'created', taskId: 'task-a' })
})

it('keeps an uncertain outcome when a stale success names another creation request', async () => {
  setStoredToken('actor-a-token', { source: 'manual' })
  let finishBody!: (body: string) => void
  let markStarted!: () => void
  const started = new Promise<void>(resolve => { markStarted = resolve })
  let rpcId = ''
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    if (url === '/health?full=1') return health()
    const request = JSON.parse(String(init.body))
    rpcId = request.id
    const response = new Response('', { status: 200 })
    response.text = () => { markStarted(); return new Promise(resolve => { finishBody = resolve }) }
    return response
  })
  vi.stubGlobal('fetch', fetchMock)
  const pending = createTask({ title: 'old', description: '' })
  await started
  setStoredToken('actor-b-token', { source: 'manual' })
  const text = JSON.stringify({ ok: true, creation_request_id: 'different-request', goal_id: null, task_id: 'foreign' })
  finishBody(JSON.stringify({ jsonrpc: '2.0', id: rpcId, result: { content: [{ type: 'text', text }] } }))
  expect(await pending).toBe(false)
  expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'unconfirmed', reason: 'response_unknown' })
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
})

it('handles a typed 401 without replaying the Task', async () => {
  setStoredToken('expired-manual-token', { source: 'manual' })
  const fetchMock = vi.fn(async (url: string) => {
    if (url === '/health?full=1') return health()
    expect(url).toBe('/mcp')
    return new Response(JSON.stringify({ error: 'expired', auth_error_code: 'token_expired' }),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  expect(await createTask({ title: 't', description: '' })).toBe(false)
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
  expect(fetchMock).toHaveBeenCalledTimes(2)
  expect(getStoredToken()).toBeNull()
  expect(mocks.showToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')
})

it.each([200, 401])('bounds a stalled %s response body and never replays the Task', async status => {
  setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
  const revision = currentStoredTokenRevision()
  let markStarted!: () => void
  const started = new Promise<void>(resolve => { markStarted = resolve })
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    if (url === '/health?full=1') return health()
    expect(url).toBe('/mcp')
    return stalledResponse(status, markStarted, init.signal!)
  })
  vi.stubGlobal('fetch', fetchMock)
  const pending = createTask({ title: 't', description: '' })
  await started
  if (status === 401) expect(managedDashboardUnverified.peek()).toBe(revision)
  await vi.advanceTimersByTimeAsync(DEFAULT_MCP_TIMEOUT_MS)
  expect(await pending).toBe(false)
  expect(taskCreating.value).toBe(false)
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
  expect(fetchMock).toHaveBeenCalledTimes(2)
  expect(getStoredToken()).toBe('dev-token')
  expect(mocks.showToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')

  if (status === 401) {
    mocks.refreshShell.mockImplementationOnce(async () => {
      setCanonicalDashboardActor('dashboard', { tokenRevision: revision, rejected: false, verifiedAfterRefusal: true })
      return true
    })
    const attempt = taskCreateReceipts.attempts.peek()[0]
    if (!attempt) throw new Error('Missing Task creation attempt')
    await recheckTaskCreation(attempt.requestId)
    expect(mocks.refreshShell).toHaveBeenCalledWith({ force: true, recoverAuth: false })
    expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
  }
})

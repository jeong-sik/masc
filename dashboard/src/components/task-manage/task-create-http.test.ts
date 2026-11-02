// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, currentStoredTokenRevision, getStoredToken, setStoredToken } from '../../api/core'
import { resetDevTokenBootstrap } from '../../api/dev-token'
import { resetMcpClientState } from '../../api/mcp'
import { DEFAULT_MCP_TIMEOUT_MS } from '../../config/constants'
import { managedDashboardUnverified, resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import { _testResetTaskCreateState, createTask, recheckTaskCreation, taskCreateReceipts, taskCreating } from './task-manage-state'

const mocks = vi.hoisted(() => ({
  authority: { peek: vi.fn() },
  refreshExecution: vi.fn(),
  refreshGoals: vi.fn(),
  refreshShell: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('../../store', () => ({ executionWorkspaceAuthority: mocks.authority,
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
    return new Response(JSON.stringify({ id: request.id, result: { content: [{ type: 'text', text }] } }),
      { status: 200, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  expect(await createTask({ title: 't', description: '' })).toBe(true)
  expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
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
  finishBody(JSON.stringify({ id: requestId, result: { content: [{ type: 'text', text }] } }))
  expect(await pending).toBe(true)
  expect(finish).not.toHaveBeenCalled()
  expect(mocks.showToast).not.toHaveBeenCalledWith('태스크 생성 완료', 'success')
  expect(mocks.refreshExecution).not.toHaveBeenCalled()
  expect(mocks.refreshGoals).not.toHaveBeenCalled()
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
  expect(mocks.showToast).not.toHaveBeenCalledWith('태스크 생성 완료', 'success')
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
  expect(mocks.showToast).not.toHaveBeenCalledWith('태스크 생성 완료', 'success')

  if (status === 401) {
    mocks.refreshShell.mockImplementationOnce(async () => {
      setCanonicalDashboardActor('dashboard', { tokenRevision: revision, rejected: false, verifiedAfterRefusal: true })
      return true
    })
    await recheckTaskCreation(taskCreateReceipts.attempts.peek()[0].requestId)
    expect(mocks.refreshShell).toHaveBeenCalledWith({ force: true, recoverAuth: false })
    expect(fetchMock.mock.calls.filter(([url]) => url === '/mcp')).toHaveLength(1)
  }
})

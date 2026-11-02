// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ fetchExecution: vi.fn(), showToast: vi.fn() }))
vi.mock('../../api/dashboard-execution', () => ({ fetchDashboardExecution: mocks.fetchExecution }))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../../api/tool-host-failure', () => ({ reportToolHostFailure: async () => {} }))

import { clearStoredToken, currentDashboardActor, currentStoredTokenRevision, setStoredToken } from '../../api/core'
import { resetMcpClientState } from '../../api/mcp'
import { DASHBOARD_AGENT_NAME_KEY, persistDashboardActorName } from '../../lib/dashboard-actor'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import * as store from '../../store'
import { goalTreeData, goalTreeError } from '../../goal-tree-state'
import { TaskCreateForm, resetForm } from './task-create-form'
import { TaskCreateReceiptsPanel } from './task-create-receipt-panel'
import { TASK_CREATE_RECEIPT_STORAGE_KEY } from './task-create-receipt'
import { _testResetTaskCreateState, acknowledgeTaskCreateResult, createTask, recheckTaskCreation, showTaskCreate,
  taskCreateReceiptOwner, taskCreateReceipts } from './task-manage-state'

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } })
}

beforeEach(() => {
  vi.resetAllMocks()
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  clearStoredToken()
  resetDashboardSessionActorForTests()
  resetMcpClientState()
  _testResetTaskCreateState()
  showTaskCreate.value = false
  resetForm()
  expect(store.hydrateExecutionSnapshot({
    execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
    status: { project: 'project-a', workspace_root: '/a' }, agents: [], tasks: [], messages: [], keepers: [],
  })).toBe(true)
  mocks.fetchExecution.mockRejectedValue(Object.assign(new Error('execution unavailable'), { status: 503 }))
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  clearStoredToken()
  resetDashboardSessionActorForTests()
  window.localStorage.removeItem(DASHBOARD_AGENT_NAME_KEY)
})

it.each(['recorded', 'denied', 'workspace-mismatch', 'workspace-change-after', 'workspace-aba', 'authority-aba',
  'token-aba', 'actor-aba', 'managed-hint'])(
  'uses only a scoped read after real execution authority withdrawal: %s', async scenario => {
    setStoredToken('actor-a-token', scenario === 'managed-hint'
      ? { source: 'dev', actor: 'dashboard', role: 'admin' } : { source: 'manual' })
    let resolveRead!: (response: Response) => void
    let readRpcId = ''
    let creationRequestId = ''
    let taskPosts = 0
    let receiptReads = 0
    let healthReads = 0
    let finishHealth!: (response: Response) => void
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url === '/health?full=1') {
        healthReads++
        if (scenario === 'authority-aba' && healthReads === 2) {
          return new Promise<Response>(resolve => { finishHealth = resolve })
        }
        return json({ paths: ((scenario === 'workspace-mismatch' && healthReads > 1)
          || (scenario === 'workspace-change-after' && healthReads > 2))
          ? { effective_base_path: '/b', effective_masc_root: '/b/.masc' }
          : { effective_base_path: '/a', effective_masc_root: '/a/.masc' } })
      }
      expect(url).toBe('/mcp')
      const request = JSON.parse(String(init?.body))
      if (request.params.name === 'masc_add_task') {
        taskPosts++
        creationRequestId = request.params.arguments.creation_request_id
        const text = JSON.stringify({ ok: true, creation_request_id: creationRequestId, goal_id: null, task_id: 'task-private' })
        return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
      }
      expect(request.params.name).toBe('masc_tasks')
      expect(request.params.arguments).toMatchObject({ creation_request_id: creationRequestId,
        expected_workspace: { base_path: '/a', masc_root: '/a/.masc' } })
      receiptReads++
      readRpcId = request.id
      return new Promise<Response>(resolve => { resolveRead = resolve })
    })
    vi.stubGlobal('fetch', fetchMock)
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    fireEvent.input(screen.getByPlaceholderText('예: runtime config introspection 정리'), { target: { value: 'first task' } })
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.fetchExecution).toHaveBeenCalledOnce())
    await waitFor(() => expect(store.executionWorkspaceAuthority.peek()).toBeNull())
    expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'created', taskId: 'task-private' })
    expect(screen.queryByText(/task-private/)).toBeNull()

    if (scenario === 'authority-aba') {
      const revision = store.executionWorkspaceRevision.peek()
      const pendingRead = recheckTaskCreation(creationRequestId)
      await waitFor(() => expect(healthReads).toBe(2))
      expect(store.hydrateExecutionSnapshot({ execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
        status: { project: 'project-a', workspace_root: '/a' }, agents: [], tasks: [], messages: [], keepers: [] })).toBe(true)
      expect(store.executionWorkspaceAuthority.peek()).not.toBeNull()
      await expect(store.refreshExecution({ force: true })).rejects.toThrow('execution unavailable')
      expect(store.executionWorkspaceAuthority.peek()).toBeNull()
      expect(store.executionWorkspaceRevision.peek()).toBe(revision)
      finishHealth(json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } }))
      await pendingRead
      expect(receiptReads).toBe(0)
      expect(taskCreateReceiptOwner.peek()).toBeNull()
      expect(screen.queryByText(/task-private/)).toBeNull()
      return
    }
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    if (scenario === 'workspace-mismatch') {
      await waitFor(() => expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('보낸 작업 공간'), 'warning'))
      expect(receiptReads).toBe(0)
      expect(taskCreateReceiptOwner.peek()).toBeNull()
      expect(screen.queryByText(/task-private/)).toBeNull()
      expect(await createTask({ title: 'another', description: '' })).toBe(false)
      expect(taskPosts).toBe(1)
      return
    }
    await waitFor(() => expect(receiptReads).toBe(1))
    expect(taskCreateReceiptOwner.peek()?.access).toBe('read_only')
    expect(taskCreateReceipts.reserve()).toEqual({ kind: 'owner_unavailable' })
    expect(taskCreateReceipts.reserveMemoryOnly()).toEqual({ kind: 'owner_unavailable' })
    expect(screen.queryByText(/task-private/)).toBeNull()
    expect(screen.queryByText(new RegExp(creationRequestId))).toBeNull()
    if (scenario === 'workspace-aba') {
      store.executionWorkspaceRevision.value++
      store.executionWorkspaceRevision.value++
    } else if (scenario === 'token-aba') {
      setStoredToken('actor-b-token', { source: 'manual' })
      setStoredToken('actor-a-token', { source: 'manual' })
    } else if (scenario === 'actor-aba') {
      setCanonicalDashboardActor('other-actor')
      setCanonicalDashboardActor(null)
    } else if (scenario === 'managed-hint') {
      persistDashboardActorName('unused-hint')
    }
    const text = JSON.stringify({ ok: true, creation_request_id: creationRequestId,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-private'] } })
    resolveRead(scenario === 'denied' ? json({ error: 'denied' }, 403)
      : json({ jsonrpc: '2.0', id: readRpcId, result: { content: [{ type: 'text', text }] } }))
    if (scenario === 'recorded' || scenario === 'managed-hint' || scenario === 'workspace-change-after') {
      await screen.findByText('task-private 생성 응답을 받았습니다.')
      expect(taskCreateReceipts.attempts.peek()[0]?.latestReadCurrent).toBe(true)
      if (scenario === 'workspace-change-after') {
        fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
        await waitFor(() => expect(taskCreateReceiptOwner.peek()).toBeNull())
        expect(screen.queryByText(/task-private/)).toBeNull()
        expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'created', taskId: 'task-private' })
        expect(receiptReads).toBe(1)
      }
    } else if (scenario === 'denied') {
      await screen.findByText(/생성 기록을 확인하지 못했습니다/)
      expect(screen.queryByText(/task-private/)).toBeNull()
    } else {
      await waitFor(() => expect(taskCreateReceipts.attempts.peek()[0]?.checking).toBe(false))
      expect(taskCreateReceipts.attempts.peek()[0]?.reads).toEqual([])
      expect(screen.queryByText(/task-private/)).toBeNull()
    }
    expect(await createTask({ title: 'another', description: '' })).toBe(false)
    expect(taskPosts).toBe(1)
  },
)

it.each(['owner-then-mismatch', 'superseded-success', 'superseded-mismatch', 'superseded-failure', 'superseded-by-failure'])(
  'orders concurrent workspace checks without reviving or clearing another owner: %s', async scenario => {
    setStoredToken('actor-a-token', { source: 'manual' })
    await expect(store.refreshExecution({ force: true })).rejects.toThrow('execution unavailable')
    const makeAttempt = (requestId: string, basePath: string, taskId: string) => ({ requestId,
      workspace: { basePath, mascRoot: `${basePath}/.masc` }, goalId: null, createdAt: '2026-11-02T00:00:00.000Z',
      original: { kind: 'created', taskId }, presented: false, reads: [] })
    sessionStorage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, JSON.stringify({ schema: TASK_CREATE_RECEIPT_STORAGE_KEY,
      attempts: [makeAttempt('request-a', '/a', 'task-a'), makeAttempt('request-b', '/b', 'task-b')] }))
    _testResetTaskCreateState({ preserveStorage: true })
    const healthResolvers: Array<(response: Response) => void> = []
    let receiptReads = 0
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      if (url === '/health?full=1') return new Promise<Response>(resolve => { healthResolvers.push(resolve) })
      expect(url).toBe('/mcp')
      receiptReads++
      const request = JSON.parse(String(init?.body))
      const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
        workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
        creation_receipt: { state: 'recorded', task_ids: ['task-a'] } })
      return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
    }))
    render(html`<${TaskCreateReceiptsPanel} />`)
    const health = (basePath: string) => json({ paths: { effective_base_path: basePath, effective_masc_root: `${basePath}/.masc` } })
    const resolveHealth = (index: number, basePath: string) => {
      const resolve = healthResolvers[index]
      if (!resolve) throw new Error('Missing health request')
      resolve(health(basePath))
    }
    const first = recheckTaskCreation(scenario === 'superseded-mismatch' || scenario === 'superseded-failure' ? 'request-b' : 'request-a')
    await waitFor(() => expect(healthResolvers).toHaveLength(1))
    if (scenario === 'owner-then-mismatch') {
      resolveHealth(0, '/a')
      await first
      await screen.findByText('task-a 생성 응답을 받았습니다.')
      const second = recheckTaskCreation('request-b')
      await waitFor(() => expect(healthResolvers).toHaveLength(2))
      resolveHealth(1, '/c')
      await second
      expect(taskCreateReceiptOwner.peek()).toBeNull()
      expect(screen.queryByText(/task-a|task-b/)).toBeNull()
      expect(receiptReads).toBe(1)
    } else {
      const second = recheckTaskCreation(scenario === 'superseded-success' || scenario === 'superseded-by-failure'
        ? 'request-b' : 'request-a')
      await waitFor(() => expect(healthResolvers).toHaveLength(2))
      if (scenario === 'superseded-by-failure') {
        const resolve = healthResolvers[1]
        if (!resolve) throw new Error('Missing health request')
        resolve(json({ error: 'unavailable' }, 503))
        await second
        resolveHealth(0, '/a')
        await first
        expect(taskCreateReceiptOwner.peek()).toBeNull()
        expect(receiptReads).toBe(0)
      } else if (scenario === 'superseded-success') {
        resolveHealth(0, '/a')
        await first
        resolveHealth(1, '/c')
        await second
        expect(taskCreateReceiptOwner.peek()).toBeNull()
        expect(receiptReads).toBe(1)
      } else {
        resolveHealth(1, '/a')
        await second
        await screen.findByText('task-a 생성 응답을 받았습니다.')
        if (scenario === 'superseded-failure') {
          const resolve = healthResolvers[0]
          if (!resolve) throw new Error('Missing health request')
          resolve(json({ error: 'unavailable' }, 503))
        } else resolveHealth(0, '/c')
        await first
        if (scenario === 'superseded-failure') expect(screen.getByText('task-a 생성 응답을 받았습니다.')).toBeTruthy()
        else {
          expect(taskCreateReceiptOwner.peek()).toBeNull()
          expect(screen.queryByText(/task-a|task-b/)).toBeNull()
        }
        expect(receiptReads).toBe(1)
      }
    }
    expect(taskCreateReceipts.attempts.peek()).toHaveLength(2)
    expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'created', taskId: 'task-a' })
    expect(taskCreateReceipts.attempts.peek()[1]?.original).toEqual({ kind: 'created', taskId: 'task-b' })
  },
)

it('checks two receipts in the same workspace independently and ignores a duplicate click', async () => {
  setStoredToken('actor-a-token', { source: 'manual' })
  await expect(store.refreshExecution({ force: true })).rejects.toThrow('execution unavailable')
  const attempt = (requestId: string, taskId: string) => ({ requestId, workspace: { basePath: '/a', mascRoot: '/a/.masc' },
    goalId: null, createdAt: '2026-11-02T00:00:00.000Z', original: { kind: 'created', taskId }, presented: false, reads: [] })
  sessionStorage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, JSON.stringify({ schema: TASK_CREATE_RECEIPT_STORAGE_KEY,
    attempts: [attempt('request-a', 'task-a'), attempt('request-b', 'task-b')] }))
  _testResetTaskCreateState({ preserveStorage: true })
  const healthResolvers: Array<(response: Response) => void> = []
  const readIds: string[] = []
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/health?full=1') return new Promise<Response>(resolve => { healthResolvers.push(resolve) })
    const request = JSON.parse(String(init?.body))
    const id: string = request.params.arguments.creation_request_id
    readIds.push(id)
    const text = JSON.stringify({ ok: true, creation_request_id: id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: [id === 'request-a' ? 'task-a' : 'task-b'] } })
    return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
  }))
  render(html`<${TaskCreateReceiptsPanel} />`)
  const first = recheckTaskCreation('request-a')
  const duplicate = recheckTaskCreation('request-a')
  const second = recheckTaskCreation('request-b')
  await duplicate
  await waitFor(() => expect(healthResolvers).toHaveLength(2))
  expect(taskCreateReceipts.attempts.peek().map(item => item.checking)).toEqual([true, true])
  const health = () => json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } })
  const resolveSecond = healthResolvers[1]
  const resolveFirst = healthResolvers[0]
  if (!resolveFirst || !resolveSecond) throw new Error('Missing health requests')
  resolveSecond(health())
  await second
  expect(screen.getByText('task-b 생성 응답을 받았습니다.')).toBeTruthy()
  expect(screen.queryByText('task-a 생성 응답을 받았습니다.')).toBeNull()
  resolveFirst(health())
  await first
  expect(screen.getByText('task-a 생성 응답을 받았습니다.')).toBeTruthy()
  expect(readIds.sort()).toEqual(['request-a', 'request-b'])
  expect(taskCreateReceipts.attempts.peek().map(item => item.checking)).toEqual([false, false])
})

it('withdraws an existing create-and-read owner when another receipt observes a different workspace', async () => {
  setStoredToken('actor-a-token', { source: 'manual' })
  const attempt = (requestId: string, basePath: string, taskId: string) => ({ requestId,
    workspace: { basePath, mascRoot: `${basePath}/.masc` }, goalId: null, createdAt: '2026-11-02T00:00:00.000Z',
    original: { kind: 'created', taskId }, presented: false, reads: [] })
  sessionStorage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, JSON.stringify({ schema: TASK_CREATE_RECEIPT_STORAGE_KEY,
    attempts: [attempt('request-a', '/a', 'task-a'), attempt('request-b', '/b', 'task-b')] }))
  _testResetTaskCreateState({ preserveStorage: true })
  let healthCount = 0
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/health?full=1') {
      const path = ++healthCount === 1 ? '/a' : '/c'
      return json({ paths: { effective_base_path: path, effective_masc_root: `${path}/.masc` } })
    }
    const request = JSON.parse(String(init?.body))
    const text = JSON.stringify({ ok: true, creation_request_id: 'request-a',
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-a'] } })
    return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
  }))
  render(html`<${TaskCreateReceiptsPanel} />`)
  await recheckTaskCreation('request-a')
  expect(taskCreateReceiptOwner.peek()?.access).toBe('create_and_read')
  expect(screen.getByText('task-a 생성 응답을 받았습니다.')).toBeTruthy()
  await recheckTaskCreation('request-b')
  expect(taskCreateReceiptOwner.peek()).toBeNull()
  expect(screen.queryByText(/task-a|task-b/)).toBeNull()
  expect(taskCreateReceipts.attempts.peek().map(item => item.original.kind)).toEqual(['created', 'created'])
})

it.each([401, 403])('hides and protects a receipt while health HTTP %i body is pending', async status => {
  setStoredToken('actor-a-token', { source: 'manual' })
  sessionStorage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, JSON.stringify({ schema: TASK_CREATE_RECEIPT_STORAGE_KEY,
    attempts: [{ requestId: 'request-private', workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      goalId: 'goal-private', createdAt: '2026-11-02T00:00:00.000Z',
      original: { kind: 'created', taskId: 'task-private' }, presented: false, reads: [] }] }))
  _testResetTaskCreateState({ preserveStorage: true })
  let healthCount = 0
  let finishBody!: (body: string) => void
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/health?full=1') {
      healthCount++
      if (healthCount === 2) {
        const response = new Response('', { status })
        response.text = () => { bodyStarted(); return new Promise(resolve => { finishBody = resolve }) }
        return response
      }
      return json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } })
    }
    const request = JSON.parse(String(init?.body))
    const text = JSON.stringify({ ok: true, creation_request_id: 'request-private',
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-private'] } })
    return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
  }))
  render(html`<${TaskCreateReceiptsPanel} />`)
  await recheckTaskCreation('request-private')
  await screen.findByText('task-private 생성 응답을 받았습니다.')
  const pending = recheckTaskCreation('request-private')
  await started
  expect(taskCreateReceipts.attempts.peek()[0]?.checking).toBe(true)
  expect(screen.queryByText(/task-private|goal-private|request-private/)).toBeNull()
  expect(screen.queryByRole('button', { name: '이 결과 확인' })).toBeNull()
  acknowledgeTaskCreateResult('request-private')
  expect(taskCreateReceipts.compact()).toMatchObject({ removedAttempts: 0, removedReads: 0, removedErrors: 0 })
  expect(taskCreateReceipts.attempts.peek()[0]?.presented).toBe(false)
  finishBody(JSON.stringify({ error: 'denied' }))
  await pending
  expect(taskCreateReceiptOwner.peek()).toBeNull()
  expect(screen.queryByText(/task-private|goal-private|request-private/)).toBeNull()
  await recheckTaskCreation('request-private')
  await screen.findByText('task-private 생성 응답을 받았습니다.')
})

it('keeps a pending receipt through automatic cleanup while its health preflight is in flight', async () => {
  setStoredToken('actor-a-token', { source: 'manual' })
  mocks.fetchExecution.mockResolvedValue({ execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
    status: { project: 'project-a', workspace_root: '/a' }, agents: [], messages: [], keepers: [],
    tasks: [{ id: 'task-private', title: 'Task', status: 'todo' }] })
  let healthCount = 0
  let finishHealth!: (response: Response) => void
  let finishPost!: (response: Response) => void
  let postRequest: { id: string; params: { arguments: { creation_request_id: string } } } | undefined
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/health?full=1') {
      healthCount++
      if (healthCount === 2) return new Promise<Response>(resolve => { finishHealth = resolve })
      return json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } })
    }
    const request = JSON.parse(String(init?.body))
    if (request.params.name === 'masc_add_task') {
      postRequest = request
      return new Promise<Response>(resolve => { finishPost = resolve })
    }
    const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-private'] } })
    return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
  }))
  render(html`<${TaskCreateReceiptsPanel} />`)
  const creating = createTask({ title: 'Task', description: '' })
  await waitFor(() => expect(postRequest).toBeDefined())
  const request = postRequest!
  const requestId = request.params.arguments.creation_request_id
  const checking = recheckTaskCreation(requestId)
  await waitFor(() => expect(healthCount).toBe(2))
  const text = JSON.stringify({ ok: true, creation_request_id: requestId, goal_id: null, task_id: 'task-private' })
  finishPost(json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } }))
  expect(await creating).toBe(true)
  expect(taskCreateReceipts.attempts.peek()[0]).toMatchObject({ checking: true, presented: false,
    original: { kind: 'created', taskId: 'task-private' } })
  acknowledgeTaskCreateResult(requestId)
  expect(taskCreateReceipts.compact()).toMatchObject({ removedAttempts: 0 })
  finishHealth(json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } }))
  await checking
  expect(taskCreateReceipts.attempts.peek()[0]?.checking).toBe(false)
  await screen.findByText('task-private 생성 응답을 받았습니다.')
})

it.each([401, 403])('hides previously authorized evidence while HTTP %i body is pending', async status => {
  setStoredToken('actor-a-token', { source: 'manual' })
  await expect(store.refreshExecution({ force: true })).rejects.toThrow('execution unavailable')
  sessionStorage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, JSON.stringify({ schema: TASK_CREATE_RECEIPT_STORAGE_KEY,
    attempts: [{ requestId: 'request-a', workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      goalId: 'goal-private', createdAt: '2026-11-02T00:00:00.000Z',
      original: { kind: 'created', taskId: 'task-private' }, presented: false, reads: [] }] }))
  _testResetTaskCreateState({ preserveStorage: true })
  let readCount = 0
  let finishBody!: (body: string) => void
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/health?full=1') return json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } })
    const request = JSON.parse(String(init?.body))
    readCount++
    if (readCount === 2) {
      const response = new Response('', { status })
      response.text = () => { bodyStarted(); return new Promise(resolve => { finishBody = resolve }) }
      return response
    }
    const text = JSON.stringify({ ok: true, creation_request_id: 'request-a',
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-private'] } })
    return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
  }))
  render(html`<${TaskCreateReceiptsPanel} />`)
  fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
  await screen.findByText('task-private 생성 응답을 받았습니다.')
  fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
  await started
  expect(taskCreateReceipts.attempts.peek()[0]?.checking).toBe(true)
  expect(screen.queryByText(/task-private|goal-private|request-a/)).toBeNull()
  expect(screen.queryByRole('button', { name: '이 결과 확인' })).toBeNull()
  acknowledgeTaskCreateResult('request-a')
  expect(taskCreateReceipts.attempts.peek()[0]?.presented).toBe(false)
  expect(taskCreateReceipts.compact()).toMatchObject({ removedAttempts: 0, removedReads: 0, removedErrors: 0 })
  finishBody(JSON.stringify({ error: 'denied' }))
  await screen.findByText(/생성 기록을 확인하지 못했습니다/)
  expect(screen.queryByText(/task-private|goal-private|request-a/)).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
  await screen.findByText('task-private 생성 응답을 받았습니다.')
  expect(readCount).toBe(3)
})

it.each(['partial', 'attested', 'nested', 'missing-attestation', 'duplicate-task', 'dropped-duplicate', 'missing-count',
  'missing-child-count', 'wrong-child-count', 'wrong-total-tasks', 'duplicate-key', 'wrong-goal'])(
  'uses the real Goal refresh and direct workspace attestation before cleanup: %s', async scenario => {
    setStoredToken('actor-a-token', { source: 'manual' })
    mocks.fetchExecution.mockResolvedValue({
      execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
      status: { project: 'project-a', workspace_root: '/a' }, agents: [], messages: [], keepers: [],
      tasks: [{ id: 'task-private', title: 'Task', goal_id: 'goal-a', status: 'todo' }],
    })
    const task: Record<string, unknown> = { id: 'task-private', title: 'Task', status: 'todo',
      is_terminal: false, created_at: '2026-01-01', updated_at: '2026-01-02' }
    if (scenario === 'wrong-goal') task.goal_id = 'another-goal'
    const goal: Record<string, unknown> = { id: 'goal-a', title: 'Goal', phase: 'executing',
      criterion_revision: 'criterion-1', measurement: { state: 'not_recorded' }, children: [], child_count: 0, task_count: 1,
      tasks: [task] }
    if (scenario === 'missing-count') delete goal.task_count
    if (scenario === 'missing-child-count') delete goal.child_count
    if (scenario === 'wrong-child-count') goal.child_count = 1
    if (scenario === 'dropped-duplicate') { goal.tasks = [task, { id: 'task-private' }]; goal.task_count = 2 }
    const other = { id: 'goal-parent', title: 'Parent', phase: 'executing', criterion_revision: 'criterion-1',
      measurement: { state: 'not_recorded' }, children: [], child_count: 0, task_count: 0, tasks: [] }
    let nodes: Record<string, unknown>[] = [goal]
    if (scenario === 'nested') nodes = [{ ...other, children: [goal], child_count: 1 }]
    if (scenario === 'duplicate-task') nodes = [goal, { ...other, tasks: [task], task_count: 1 }]
    const totalGoals = scenario === 'nested' || scenario === 'duplicate-task' ? 2 : 1
    const tree = { approval_queue_state: { state: 'ready' }, tree: nodes,
      summary: { total_goals: totalGoals, active_goals: totalGoals, phase_counts: {}, total_tasks: scenario === 'wrong-total-tasks' ? 0 : 1,
        done_tasks: 0, pending_approvals: 0 } }
    let directReads = 0
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url === '/api/v1/dashboard/planning') {
        return scenario === 'partial' ? json({ error: 'planning unavailable' }, 503)
          : json({ goals: [], rollup: { active_count: 0, verifying_count: 0, awaiting_confirmation_count: 0,
            done_count: 0, dropped_count: 0, paused_count: 0, blocked_count: 0 } })
      }
      if (url === '/api/v1/dashboard/goals') return json(tree)
      if (url.startsWith('/api/v1/dashboard/goals?')) {
        directReads++
        const headers = new Headers({ 'content-type': 'application/json' })
        if (scenario !== 'missing-attestation') {
          headers.set('x-masc-workspace-read', 'matched-v1')
          headers.set('x-masc-goal-tree-read', 'direct-v1')
        }
        const body = scenario === 'duplicate-key'
          ? JSON.stringify(tree).replace('"total_tasks":1', '"total_tasks":1,"total_tasks":1') : JSON.stringify(tree)
        return new Response(body, { status: 200, headers })
      }
      expect(url).toBe('/mcp')
      const request = JSON.parse(String(init?.body))
      const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
        goal_id: 'goal-a', task_id: 'task-private' })
      return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
    })
    vi.stubGlobal('fetch', fetchMock)
    const authority = store.executionWorkspaceAuthority.peek()
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: currentStoredTokenRevision(), actor: currentDashboardActor() },
      isCurrent: () => store.executionWorkspaceAuthority.peek() === authority }
    expect(await createTask({ title: 't', description: '', goal_id: 'goal-a' }, dispatch)).toBe(true)
    if (scenario === 'partial') {
      expect(goalTreeData.peek()).toBeNull()
      expect(goalTreeError.peek()).not.toBeNull()
      expect(directReads).toBe(0)
    } else if (scenario === 'attested' || scenario === 'nested' || scenario === 'missing-attestation' || scenario === 'duplicate-key') expect(directReads).toBe(1)
    else expect(directReads).toBe(0)
    if (scenario === 'attested' || scenario === 'nested') expect(taskCreateReceipts.attempts.peek()).toHaveLength(0)
    else expect(taskCreateReceipts.attempts.peek()[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-private' },
      presented: false })
  },
)

it.each([401, 403])('treats scoped Goal HTTP %i as a Goal response while its body is delayed', async status => {
  setStoredToken('actor-a-token', { source: 'manual' })
  mocks.fetchExecution.mockResolvedValue({ execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
    status: { project: 'project-a', workspace_root: '/a' }, agents: [], messages: [], keepers: [],
    tasks: [{ id: 'task-private', title: 'Task', status: 'todo', goal_id: 'goal-a' }] })
  const tree = { approval_queue_state: { state: 'ready' }, tree: [{ id: 'goal-a', title: 'Goal', phase: 'executing',
    criterion_revision: 'criterion-1', measurement: { state: 'not_recorded' }, children: [], child_count: 0, task_count: 1,
    tasks: [{ id: 'task-private', title: 'Task', status: 'todo', is_terminal: false,
      created_at: '2026-01-01', updated_at: '2026-01-02' }] }],
  summary: { total_goals: 1, active_goals: 1, phase_counts: {}, total_tasks: 1, done_tasks: 0, pending_approvals: 0 } }
  let finishBody!: (body: string) => void
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  let finishGoalHeaders!: (response: Response) => void
  let goalStarted!: () => void
  const goalPending = new Promise<void>(resolve => { goalStarted = resolve })
  let finishHealth!: (response: Response) => void
  let healthStarted!: () => void
  const healthPending = new Promise<void>(resolve => { healthStarted = resolve })
  let receiptReads = 0
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/health?full=1') {
      healthStarted()
      return new Promise<Response>(resolve => { finishHealth = resolve })
    }
    if (url === '/api/v1/dashboard/planning') return json({ goals: [], rollup: { active_count: 0, verifying_count: 0,
      awaiting_confirmation_count: 0, done_count: 0, dropped_count: 0, paused_count: 0, blocked_count: 0 } })
    if (url === '/api/v1/dashboard/goals') return json(tree)
    if (url.startsWith('/api/v1/dashboard/goals?')) {
      goalStarted()
      return new Promise<Response>(resolve => { finishGoalHeaders = resolve })
    }
    const request = JSON.parse(String(init?.body))
    const requestId = request.params.arguments.creation_request_id
    if (request.params.name === 'masc_tasks') receiptReads++
    const text = request.params.name === 'masc_tasks'
      ? JSON.stringify({ ok: true, creation_request_id: requestId, workspace: { base_path: '/a', masc_root: '/a/.masc' },
        backlog_version: 5, creation_receipt: { state: 'recorded', task_ids: ['task-private'] } })
      : JSON.stringify({ ok: true, creation_request_id: requestId, goal_id: 'goal-a', task_id: 'task-private' })
    return json({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text }] } })
  }))
  render(html`<${TaskCreateReceiptsPanel} />`)
  const authority = store.executionWorkspaceAuthority.peek()
  const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
    identity: { revision: currentStoredTokenRevision(), actor: currentDashboardActor() },
    isCurrent: () => store.executionWorkspaceAuthority.peek() === authority }
  const creating = createTask({ title: 'Task', description: '', goal_id: 'goal-a' }, dispatch)
  await goalPending
  const requestId = taskCreateReceipts.attempts.peek()[0]?.requestId
  if (!requestId) throw new Error('Missing Task request')
  const checking = recheckTaskCreation(requestId)
  await healthPending
  const response = new Response('', { status })
  response.text = () => { bodyStarted(); return new Promise(resolve => { finishBody = resolve }) }
  finishGoalHeaders(response)
  await started
  finishHealth(json({ paths: { effective_base_path: '/a', effective_masc_root: '/a/.masc' } }))
  await checking
  if (status === 401) {
    expect(taskCreateReceiptOwner.peek()).toBeNull()
    expect(screen.queryByText(/task-private|goal-a/)).toBeNull()
    expect(receiptReads).toBe(0)
  } else {
    expect(taskCreateReceiptOwner.peek()).not.toBeNull()
    expect(screen.getByText('task-private 생성 응답을 받았습니다.')).toBeTruthy()
    expect(receiptReads).toBe(1)
  }
  finishBody(JSON.stringify({ error: 'denied' }))
  expect(await creating).toBe(true)
  expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'created', taskId: 'task-private' })
})

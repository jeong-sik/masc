// @vitest-environment happy-dom
import { signal } from '@preact/signals'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ call: vi.fn() }))
vi.mock('../../api/mcp', () => ({ callMcpTaskReceiptAtIdentity: (args: unknown, identity: unknown, current: unknown) =>
  mocks.call('masc_tasks', args, identity, current) }))

import {
  TASK_CREATE_RECEIPT_STORAGE_KEY,
  createTaskCreateReceiptStore,
  decodeTaskCreationReceipt,
  decodeTaskCreationResponse,
  type TaskReceiptOwner,
} from './task-create-receipt'

const workspaceA = { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }
const workspaceB = { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' }

class MemoryStorage {
  value: string | null = null
  failRead = false
  failWrite = false
  maxBytes = Infinity
  getItem(key: string): string | null {
    expect(key).toBe(TASK_CREATE_RECEIPT_STORAGE_KEY)
    if (this.failRead) throw new Error('storage read unavailable')
    return this.value
  }
  setItem(key: string, value: string): void {
    expect(key).toBe(TASK_CREATE_RECEIPT_STORAGE_KEY)
    if (this.failWrite || value.length > this.maxBytes) throw new Error('storage write unavailable')
    this.value = value
  }
}

function owner(workspace = workspaceA): TaskReceiptOwner {
  return { workspace, identity: { revision: 1, actor: 'dashboard' }, access: 'create_and_read', isCurrent: () => true }
}

function response(requestId: string, state: string, taskIds: string[], workspace = workspaceA, version = 5): string {
  return JSON.stringify({ ok: true, creation_request_id: requestId,
    workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot }, backlog_version: version,
    creation_receipt: { state, task_ids: taskIds } })
}

function setup(options?: { storage?: MemoryStorage; lookup?: (owner: TaskReceiptOwner, id: string, current: () => boolean) => Promise<string> }) {
  const ownerSignal = signal<TaskReceiptOwner | null>(owner())
  const storage = options?.storage ?? new MemoryStorage()
  let nextId = 0
  const store = createTaskCreateReceiptStore({ owner: ownerSignal, storage, lookup: options?.lookup,
    newRequestId: () => `request-${++nextId}` })
  return { ownerSignal, storage, store }
}

function reserve(store: ReturnType<typeof createTaskCreateReceiptStore>, goalId: string | null = null) {
  const result = store.reserve(goalId)
  expect(result.kind).toBe('reserved')
  if (result.kind !== 'reserved') throw new Error('reservation failed')
  return result.reservation
}

describe('Task creation receipts', () => {
  beforeEach(() => { mocks.call.mockReset() })

  it('persists an original request before dispatch without Task body or credentials', () => {
    const { store, storage } = setup()
    const request = reserve(store, 'goal-a')
    expect(request.requestId).toBe('request-1')
    expect(request.isCurrent()).toBe(true)
    expect(request.persistence).toBe('session')
    expect(mocks.call).not.toHaveBeenCalled()
    const saved = JSON.parse(storage.value!)
    expect(saved.attempts).toEqual([{ requestId: 'request-1', workspace: workspaceA, goalId: 'goal-a',
      createdAt: expect.any(String), original: { kind: 'pending' }, presented: false, reads: [] }])
    expect(storage.value).not.toContain('"actor"')
    expect(storage.value).not.toContain('title')
    expect(storage.value).not.toContain('description')
    expect(storage.value).not.toContain('token')
    store.dispose()
  })

  it('restores an outstanding original as unconfirmed without replaying it', () => {
    const { store, storage } = setup()
    reserve(store)
    store.dispose()
    const nextOwner = signal<TaskReceiptOwner | null>(owner())
    const restored = createTaskCreateReceiptStore({ owner: nextOwner, storage })
    expect(restored.attempts.value[0]).toMatchObject({ original: { kind: 'unconfirmed', reason: 'interrupted' },
      originalCurrent: false, latestReadCurrent: false, checking: false })
    expect(mocks.call).not.toHaveBeenCalled()
    restored.dispose()
  })

  it('refuses a failed durable reservation, and offers memory-only only by an explicit call', () => {
    const storage = new MemoryStorage()
    const { store } = setup({ storage })
    storage.failWrite = true
    expect(store.reserve()).toEqual({ kind: 'storage_unavailable' })
    expect(store.storageState.value).toBe('write_failed')
    expect(store.attempts.value).toHaveLength(0)
    expect(mocks.call).not.toHaveBeenCalled()
    const memory = store.reserveMemoryOnly()
    expect(memory.kind).toBe('reserved')
    if (memory.kind !== 'reserved') throw new Error('memory reservation failed')
    expect(memory.reservation.persistence).toBe('memory')
    expect(store.settleOriginal(memory.reservation.requestId, { kind: 'unconfirmed', reason: 'response_unknown' }))
      .toEqual({ kind: 'settled', persisted: false })
    storage.failWrite = false
    expect(store.retryStorage()).toBe(true)
    expect(JSON.parse(storage.value!).attempts).toEqual([])
    expect(store.attempts.value).toHaveLength(1)
    reserve(store)
    expect(JSON.parse(storage.value!).attempts).toHaveLength(1)
    expect(JSON.parse(storage.value!).attempts[0].requestId).not.toBe(memory.reservation.requestId)
    expect(mocks.call).not.toHaveBeenCalled()
    store.dispose()
  })

  it('does not overwrite corrupt stored evidence when reserving or explicitly using memory', () => {
    const storage = new MemoryStorage()
    storage.value = '{not valid json'
    const { store } = setup({ storage })
    expect(store.storageState.value).toBe('corrupt')
    expect(store.reserve()).toEqual({ kind: 'storage_unavailable' })
    expect(store.reserveMemoryOnly().kind).toBe('reserved')
    expect(storage.value).toBe('{not valid json')
    storage.value = null
    expect(store.retryStorage()).toBe(true)
    expect(store.attempts.value).toHaveLength(1)
    expect(store.attempts.value[0]?.persistence).toBe('memory')
    store.dispose()
  })

  it('does not treat a storage failure after a sent call as a failed creation', () => {
    const { store, storage } = setup()
    const request = reserve(store)
    storage.failWrite = true
    expect(store.settleOriginal(request.requestId, { kind: 'created', taskId: 'task-1' }))
      .toEqual({ kind: 'settled', persisted: false })
    expect(store.attempts.value[0]?.original).toEqual({ kind: 'created', taskId: 'task-1' })
    expect(store.storageState.value).toBe('write_failed')
    storage.failWrite = false
    const restored = createTaskCreateReceiptStore({ owner: signal(owner()), storage })
    expect(restored.attempts.value[0]?.original).toEqual({ kind: 'unconfirmed', reason: 'interrupted' })
    expect(store.retryStorage()).toBe(true)
    expect(JSON.parse(storage.value!).attempts[0].original).toEqual({ kind: 'created', taskId: 'task-1' })
    restored.dispose()
    store.dispose()
  })

  it('restores an unpresented success until its confirmation has been presented', () => {
    const { store, storage } = setup()
    const request = reserve(store, 'goal-a')
    store.settleOriginal(request.requestId, { kind: 'created', taskId: 'task-1' })
    const unread = createTaskCreateReceiptStore({ owner: signal(owner()), storage })
    expect(unread.attempts.value[0]).toMatchObject({ requestId: request.requestId, goalId: 'goal-a',
      createdAt: expect.any(String), presented: false, original: { kind: 'created', taskId: 'task-1' } })
    unread.dispose()
    expect(store.markPresented(request.requestId)).toBe(true)
    const presented = createTaskCreateReceiptStore({ owner: signal(owner()), storage })
    expect(presented.attempts.value[0]?.presented).toBe(true)
    expect(mocks.call).not.toHaveBeenCalled()
    presented.dispose()
    store.dispose()
  })

  it('compacts only definite presented outcomes and repeated errors, preserving unresolved and ambiguous evidence', async () => {
    const { store, storage } = setup()
    const refused = reserve(store)
    store.settleOriginal(refused.requestId, { kind: 'rejected_before_effect' })
    const confirmed = reserve(store)
    store.settleOriginal(confirmed.requestId, { kind: 'created', taskId: 'task-confirmed' })
    store.markPresented(confirmed.requestId)
    const unknown = reserve(store)
    store.settleOriginal(unknown.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    mocks.call.mockRejectedValueOnce(new Error('read failed'))
      .mockRejectedValueOnce(new Error('read failed again'))
      .mockResolvedValueOnce(response(unknown.requestId, 'ambiguous', ['task-a', 'task-b']))
      .mockRejectedValueOnce(new Error('still unavailable'))
      .mockResolvedValueOnce(response(unknown.requestId, 'not_observed', [], workspaceA, 8))
    await store.observe(unknown.requestId)
    await store.observe(unknown.requestId)
    await store.observe(unknown.requestId)
    await store.observe(unknown.requestId)
    await store.observe(unknown.requestId)
    expect(store.compact()).toEqual({ removedAttempts: 2, removedErrors: 1, removedReads: 0, persisted: true })
    expect(store.attempts.value).toHaveLength(1)
    expect(store.attempts.value[0]).toMatchObject({ requestId: unknown.requestId,
      original: { kind: 'unconfirmed', reason: 'response_unknown' },
      reads: [{ kind: 'error', reason: 'lookup_failed' }, { kind: 'ambiguous', taskIds: ['task-a', 'task-b'] },
        { kind: 'error', reason: 'lookup_failed' }, { kind: 'not_observed', backlogVersion: 8 }] })
    const restored = createTaskCreateReceiptStore({ owner: signal(owner()), storage })
    expect(restored.attempts.value[0]?.reads).toEqual(store.attempts.value[0]?.reads)
    restored.dispose()
    store.dispose()
  })

  it.each(['different-task', 'not-observed-before-success', 'negative-then-matching'])(
    'retains a presented creation with potentially conflicting evidence: %s', async scenario => {
      const { store, storage } = setup()
      const request = reserve(store)
      if (scenario === 'not-observed-before-success') {
        mocks.call.mockResolvedValueOnce(response(request.requestId, 'not_observed', [], workspaceA, 5))
        await store.observe(request.requestId)
      }
      store.settleOriginal(request.requestId, { kind: 'created', taskId: 'task-a' })
      if (scenario === 'different-task') {
        mocks.call.mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-b'], workspaceA, 6))
        await store.observe(request.requestId)
      }
      if (scenario === 'negative-then-matching') {
        mocks.call.mockResolvedValueOnce(response(request.requestId, 'not_observed', [], workspaceA, 5))
          .mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-a'], workspaceA, 6))
        await store.observe(request.requestId)
        await store.observe(request.requestId)
      }
      store.markPresented(request.requestId)
      expect(store.forgetDefinite(request.requestId)).toBe(false)
      expect(store.compact()).toMatchObject({ removedAttempts: 0, persisted: true })
      expect(store.attempts.value[0]?.original).toEqual({ kind: 'created', taskId: 'task-a' })
      expect(store.attempts.value[0]?.reads.length).toBeGreaterThan(0)
      const restored = createTaskCreateReceiptStore({ owner: signal(owner()), storage })
      expect(restored.attempts.value[0]?.reads).toEqual(store.attempts.value[0]?.reads)
      restored.dispose()
      store.dispose()
    },
  )

  it.each(['not_sent', 'rejected_before_effect'] as const)(
    'retains a %s original if a creation receipt exists', async kind => {
      const { store } = setup()
      const request = reserve(store)
      store.settleOriginal(request.requestId, { kind })
      mocks.call.mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-a']))
      await store.observe(request.requestId)
      expect(store.forgetDefinite(request.requestId)).toBe(false)
      expect(store.compact()).toMatchObject({ removedAttempts: 0 })
      expect(store.attempts.value[0]?.reads).toEqual([{ kind: 'recorded', taskId: 'task-a', backlogVersion: 5 }])
      store.dispose()
    },
  )

  it('can explicitly free failed storage without losing an unresolved request', () => {
    const { store, storage } = setup()
    const confirmed = reserve(store)
    store.settleOriginal(confirmed.requestId, { kind: 'created', taskId: 'task-1' })
    store.markPresented(confirmed.requestId)
    const unknown = reserve(store)
    store.settleOriginal(unknown.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    storage.failWrite = true
    expect(store.reserve()).toEqual({ kind: 'storage_unavailable' })
    expect(store.storageState.value).toBe('write_failed')
    storage.failWrite = false
    expect(store.compact()).toEqual({ removedAttempts: 1, removedErrors: 0, removedReads: 0, persisted: true })
    expect(store.storageState.value).toBe('ready')
    expect(store.attempts.value.map(item => item.requestId)).toEqual([unknown.requestId])
    expect(JSON.parse(storage.value!).attempts[0].original.kind).toBe('unconfirmed')
    expect(store.reserve().kind).toBe('reserved')
    store.dispose()
  })

  it('forgets only the requested definite result and retains it when deletion cannot be saved', async () => {
    const { store, storage } = setup()
    const confirmed = reserve(store)
    store.settleOriginal(confirmed.requestId, { kind: 'created', taskId: 'task-1' })
    store.markPresented(confirmed.requestId)
    const unknown = reserve(store)
    store.settleOriginal(unknown.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    const ambiguous = reserve(store)
    store.settleOriginal(ambiguous.requestId, { kind: 'created', taskId: 'task-a' })
    store.markPresented(ambiguous.requestId)
    mocks.call.mockResolvedValueOnce(response(ambiguous.requestId, 'ambiguous', ['task-a', 'task-b']))
    await store.observe(ambiguous.requestId)
    expect(store.forgetDefinite(unknown.requestId)).toBe(false)
    expect(store.forgetDefinite(ambiguous.requestId)).toBe(false)
    storage.failWrite = true
    expect(store.forgetDefinite(confirmed.requestId)).toBe(false)
    expect(store.attempts.value).toHaveLength(3)
    storage.failWrite = false
    expect(store.retryStorage()).toBe(true)
    expect(store.forgetDefinite(confirmed.requestId)).toBe(true)
    expect(store.attempts.value.map(item => item.requestId)).toEqual([unknown.requestId, ambiguous.requestId])
    expect(store.attempts.value[1]?.reads[0]).toMatchObject({ kind: 'ambiguous' })
    store.dispose()
  })

  it('keeps the original transport unknown when an exact creation fact is observed', async () => {
    const { store } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    mocks.call.mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-17']))
    const outcome = await store.observe(request.requestId)
    expect(outcome).toEqual({ kind: 'observed', result: { kind: 'recorded', taskId: 'task-17', backlogVersion: 5 }, persisted: true })
    expect(store.attempts.value[0]?.original).toEqual({ kind: 'unconfirmed', reason: 'response_unknown' })
    expect(store.attempts.value[0]?.latestReadCurrent).toBe(true)
    expect(mocks.call).toHaveBeenCalledOnce()
    expect(mocks.call).toHaveBeenCalledWith('masc_tasks', { creation_request_id: request.requestId,
      expected_workspace: { base_path: workspaceA.basePath, masc_root: workspaceA.mascRoot } },
    request.identity, expect.any(Function))
    store.dispose()
  })

  it('retains not-observed, later facts, ambiguity, and read failures separately', async () => {
    const { store } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'server_error' })
    mocks.call.mockResolvedValueOnce(response(request.requestId, 'not_observed', []))
      .mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-1'], workspaceA, 6))
      .mockResolvedValueOnce(response(request.requestId, 'ambiguous', ['task-1', 'task-2'], workspaceA, 7))
      .mockRejectedValueOnce(new Error('private server output'))
    await store.observe(request.requestId)
    expect(store.attempts.value[0]?.original.kind).toBe('unconfirmed')
    await store.observe(request.requestId)
    await store.observe(request.requestId)
    await store.observe(request.requestId)
    expect(store.attempts.value[0]?.reads).toEqual([
      { kind: 'not_observed', backlogVersion: 5 },
      { kind: 'recorded', taskId: 'task-1', backlogVersion: 6 },
      { kind: 'ambiguous', taskIds: ['task-1', 'task-2'], backlogVersion: 7 },
      { kind: 'error', reason: 'lookup_failed' },
    ])
    expect(mocks.call).toHaveBeenCalledTimes(4)
    expect(JSON.stringify(store.attempts.value)).not.toContain('private server output')
    store.dispose()
  })

  it('does not accumulate identical recorded or not-observed facts, and retains distinct observations', async () => {
    const { store, storage } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    mocks.call.mockResolvedValueOnce(response(request.requestId, 'not_observed', [], workspaceA, 5))
      .mockResolvedValueOnce(response(request.requestId, 'not_observed', [], workspaceA, 5))
      .mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-1'], workspaceA, 6))
      .mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-1'], workspaceA, 6))
      .mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-1'], workspaceA, 7))
      .mockResolvedValueOnce(response(request.requestId, 'ambiguous', ['task-1', 'task-2'], workspaceA, 8))
      .mockResolvedValueOnce(response(request.requestId, 'ambiguous', ['task-1', 'task-2'], workspaceA, 8))
      .mockResolvedValueOnce(response(request.requestId, 'ambiguous', ['task-1', 'task-3'], workspaceA, 8))
    for (let i = 0; i < 8; i++) await store.observe(request.requestId)
    expect(store.attempts.value[0]?.original).toEqual({ kind: 'unconfirmed', reason: 'response_unknown' })
    expect(store.attempts.value[0]?.reads).toEqual([
      { kind: 'not_observed', backlogVersion: 5 },
      { kind: 'not_observed', backlogVersion: 5 },
      { kind: 'recorded', taskId: 'task-1', backlogVersion: 6 },
      { kind: 'recorded', taskId: 'task-1', backlogVersion: 7 },
      { kind: 'ambiguous', taskIds: ['task-1', 'task-2'], backlogVersion: 8 },
      { kind: 'ambiguous', taskIds: ['task-1', 'task-2'], backlogVersion: 8 },
      { kind: 'ambiguous', taskIds: ['task-1', 'task-3'], backlogVersion: 8 },
    ])
    expect(JSON.parse(storage.value!).attempts[0].reads).toHaveLength(7)
    store.dispose()
  })

  it('coalesces repeated read failures without losing distinct errors or original evidence', async () => {
    const { store } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    mocks.call.mockRejectedValueOnce(new Error('HTTP 403'))
      .mockRejectedValueOnce(new Error('HTTP 403 again'))
      .mockResolvedValueOnce('invalid JSON')
      .mockResolvedValueOnce('still invalid JSON')
      .mockResolvedValueOnce(response(request.requestId, 'not_observed', []))
    for (let i = 0; i < 5; i++) await store.observe(request.requestId)
    expect(store.attempts.value[0]).toMatchObject({ original: { kind: 'unconfirmed', reason: 'response_unknown' },
      reads: [{ kind: 'error', reason: 'lookup_failed' }, { kind: 'error', reason: 'lookup_failed' },
        { kind: 'error', reason: 'invalid_response' }, { kind: 'error', reason: 'invalid_response' },
        { kind: 'not_observed', backlogVersion: 5 }] })
    store.dispose()
  })

  it('bounds alternating same-version successes and errors while preserving their last kind', async () => {
    const { store } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    for (let index = 0; index < 60; index++) {
      mocks.call.mockResolvedValueOnce(response(request.requestId, 'recorded', ['task-a'], workspaceA, 5))
      await store.observe(request.requestId)
      expect(store.attempts.value[0]?.reads.at(-1)).toEqual({ kind: 'recorded', taskId: 'task-a', backlogVersion: 5 })
      expect(store.attempts.value[0]?.latestReadCurrent).toBe(true)
      mocks.call.mockRejectedValueOnce(new Error('transient'))
      await store.observe(request.requestId)
      expect(store.attempts.value[0]?.reads.at(-1)).toEqual({ kind: 'error', reason: 'lookup_failed' })
      expect(store.attempts.value[0]?.latestReadFailureCurrent).toBe(true)
      expect(store.attempts.value[0]?.reads.length).toBeLessThanOrEqual(5)
    }
    expect(store.attempts.value[0]?.original).toEqual({ kind: 'unconfirmed', reason: 'response_unknown' })
    expect(store.attempts.value[0]?.reads).toEqual([
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 5 },
      { kind: 'error', reason: 'lookup_failed' },
      { kind: 'error', reason: 'lookup_failed' },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 5 },
      { kind: 'error', reason: 'lookup_failed' },
    ])
    store.dispose()
  })

  it('preserves first and last errors of each kind across successful observations and transitions', async () => {
    const { store } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    const sequence: Array<string | Error> = [
      response(request.requestId, 'recorded', ['task-a'], workspaceA, 5), new Error('down'),
      response(request.requestId, 'recorded', ['task-a'], workspaceA, 6), '{bad',
      response(request.requestId, 'recorded', ['task-a'], workspaceA, 7), new Error('down again'),
      response(request.requestId, 'recorded', ['task-a'], workspaceA, 7), '{still bad',
      response(request.requestId, 'recorded', ['task-a'], workspaceA, 6), new Error('after reversal'),
      response(request.requestId, 'recorded', ['task-b'], workspaceA, 7),
      response(request.requestId, 'not_observed', [], workspaceA, 8),
    ]
    for (const item of sequence) {
      if (item instanceof Error) mocks.call.mockRejectedValueOnce(item)
      else mocks.call.mockResolvedValueOnce(item)
      await store.observe(request.requestId)
    }
    expect(store.attempts.value[0]?.reads).toEqual([
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 5 },
      { kind: 'error', reason: 'lookup_failed' },
      { kind: 'error', reason: 'invalid_response' },
      { kind: 'error', reason: 'lookup_failed' },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 7 },
      { kind: 'error', reason: 'invalid_response' },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 6 },
      { kind: 'error', reason: 'lookup_failed' },
      { kind: 'recorded', taskId: 'task-b', backlogVersion: 7 },
      { kind: 'not_observed', backlogVersion: 8 },
    ])
    store.dispose()
  })

  it('summarizes increasing versions but preserves reversal, status changes, and different Task IDs', async () => {
    const { store } = setup()
    const request = reserve(store)
    store.settleOriginal(request.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
    const versions: Array<[string, string[], number]> = [
      ['recorded', ['task-a'], 5], ['recorded', ['task-a'], 6], ['recorded', ['task-a'], 7],
      ['recorded', ['task-a'], 6], ['recorded', ['task-a'], 7], ['recorded', ['task-a'], 8],
      ['recorded', ['task-b'], 9], ['recorded', ['task-b'], 10],
      ['not_observed', [], 11], ['not_observed', [], 12], ['recorded', ['task-a'], 13],
    ]
    for (const [state, ids, version] of versions) {
      mocks.call.mockResolvedValueOnce(response(request.requestId, state, ids, workspaceA, version))
      await store.observe(request.requestId)
    }
    expect(store.attempts.value[0]?.original).toEqual({ kind: 'unconfirmed', reason: 'response_unknown' })
    expect(store.attempts.value[0]?.reads).toEqual([
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 5 },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 7 },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 6 },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 8 },
      { kind: 'recorded', taskId: 'task-b', backlogVersion: 9 },
      { kind: 'recorded', taskId: 'task-b', backlogVersion: 10 },
      { kind: 'not_observed', backlogVersion: 11 },
      { kind: 'not_observed', backlogVersion: 12 },
      { kind: 'recorded', taskId: 'task-a', backlogVersion: 13 },
    ])
    store.dispose()
  })

  it('compacts authorized legacy observations and can reserve again within a storage quota', async () => {
    const storage = new MemoryStorage()
    const legacyReads = [
      ...Array.from({ length: 16 }, (_, i) => ({ kind: 'not_observed', backlogVersion: i + 1 })),
      ...Array.from({ length: 16 }, (_, i) => ({ kind: 'recorded', taskId: 'task-old', backlogVersion: i + 17 })),
    ]
    storage.value = JSON.stringify({ schema: TASK_CREATE_RECEIPT_STORAGE_KEY, attempts: [{ requestId: 'legacy',
      workspace: workspaceA, goalId: null, createdAt: '2026-11-02T00:00:00.000Z',
      original: { kind: 'unconfirmed', reason: 'response_unknown' }, presented: false, reads: legacyReads }] })
    storage.maxBytes = storage.value.length - 100
    const { store } = setup({ storage })
    mocks.call.mockResolvedValueOnce(response('legacy', 'recorded', ['task-new'], workspaceA, 33))
    expect(await store.observe('legacy')).toMatchObject({ kind: 'observed', persisted: false })
    expect(store.storageState.value).toBe('write_failed')
    expect(store.compact()).toEqual({ removedAttempts: 0, removedErrors: 0, removedReads: 28, persisted: true })
    expect(store.attempts.value[0]).toMatchObject({ original: { kind: 'unconfirmed', reason: 'response_unknown' },
      reads: [{ kind: 'not_observed', backlogVersion: 1 }, { kind: 'not_observed', backlogVersion: 16 },
        { kind: 'recorded', taskId: 'task-old', backlogVersion: 17 },
        { kind: 'recorded', taskId: 'task-old', backlogVersion: 32 },
        { kind: 'recorded', taskId: 'task-new', backlogVersion: 33 }] })
    expect(store.reserve().kind).toBe('reserved')
    store.dispose()
  })

  it.each(['denied', 'invalid'])('does not authorize stored evidence or compaction on a %s read after owner change', async (kind) => {
    const { store, ownerSignal, storage } = setup()
    const request = reserve(store, 'goal-a')
    store.settleOriginal(request.requestId, { kind: 'created', taskId: 'task-a' })
    store.markPresented(request.requestId)
    ownerSignal.value = owner()
    if (kind === 'denied') mocks.call.mockRejectedValueOnce(new Error('HTTP 403'))
    else mocks.call.mockResolvedValueOnce(response('another-request', 'recorded', ['task-a']))
    const result = await store.observe(request.requestId)
    expect(result).toMatchObject({ kind: 'observed', result: { kind: 'error' } })
    expect(store.attempts.value[0]).toMatchObject({ originalCurrent: false, latestReadCurrent: false,
      latestReadFailureCurrent: true })
    expect(store.compact()).toEqual({ removedAttempts: 0, removedErrors: 0, removedReads: 0, persisted: true })
    expect(store.attempts.value[0]?.original).toEqual({ kind: 'created', taskId: 'task-a' })
    const restored = createTaskCreateReceiptStore({ owner: signal(owner()), storage })
    expect(restored.attempts.value[0]).toMatchObject({ originalCurrent: false, latestReadCurrent: false,
      latestReadFailureCurrent: false })
    restored.dispose()
    store.dispose()
  })

  it('does not admit a read that returned after owner A → B → A', async () => {
    let resolveRead!: (value: string) => void
    const { store, ownerSignal } = setup({ lookup: () => new Promise(resolve => { resolveRead = resolve }) })
    const request = reserve(store)
    const originalOwner = ownerSignal.peek()!
    const pending = store.observe(request.requestId)
    expect(store.attempts.value[0]?.checking).toBe(true)
    ownerSignal.value = owner(workspaceB)
    ownerSignal.value = originalOwner
    expect(request.isCurrent()).toBe(false)
    expect(store.attempts.value[0]?.checking).toBe(false)
    resolveRead(response(request.requestId, 'recorded', ['task-a']))
    expect(await pending).toEqual({ kind: 'stale' })
    expect(store.attempts.value[0]?.reads).toEqual([])
    store.settleOriginal(request.requestId, { kind: 'created', taskId: 'task-a' })
    expect(store.attempts.value[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-a' },
      originalCurrent: false, latestReadCurrent: false })
    store.dispose()
  })

  it('retires a prior observation and permits a fresh explicit read after ownership changes', async () => {
    const { store, ownerSignal } = setup()
    const request = reserve(store)
    mocks.call.mockResolvedValue(response(request.requestId, 'recorded', ['task-a']))
    await store.observe(request.requestId)
    const originalOwner = ownerSignal.peek()!
    ownerSignal.value = owner(workspaceB)
    expect(await store.observe(request.requestId)).toEqual({ kind: 'workspace_mismatch' })
    ownerSignal.value = originalOwner
    expect(store.attempts.value[0]?.latestReadCurrent).toBe(false)
    expect((await store.observe(request.requestId)).kind).toBe('observed')
    expect(store.attempts.value[0]?.latestReadCurrent).toBe(true)
    expect(mocks.call).toHaveBeenCalledTimes(2)
    store.dispose()
  })

  it('coalesces duplicate read requests without dispatching an additional lookup', async () => {
    let resolveRead!: (value: string) => void
    const lookup = vi.fn(() => new Promise<string>(resolve => { resolveRead = resolve }))
    const { store } = setup({ lookup })
    const request = reserve(store)
    const first = store.observe(request.requestId)
    expect(await store.observe(request.requestId)).toEqual({ kind: 'already_checking' })
    expect(lookup).toHaveBeenCalledOnce()
    resolveRead(response(request.requestId, 'not_observed', []))
    expect((await first).kind).toBe('observed')
    store.dispose()
  })
})

describe('Task creation receipt decoding', () => {
  const requestId = 'request-1'
  it('accepts only exact identities and the cardinality of each state', () => {
    expect(decodeTaskCreationReceipt(response(requestId, 'not_observed', []), requestId, workspaceA))
      .toEqual({ kind: 'not_observed', backlogVersion: 5 })
    expect(decodeTaskCreationReceipt(response(requestId, 'recorded', ['task-a']), requestId, workspaceA))
      .toEqual({ kind: 'recorded', taskId: 'task-a', backlogVersion: 5 })
    expect(decodeTaskCreationReceipt(response(requestId, 'ambiguous', ['task-a', 'task-b']), requestId, workspaceA))
      .toEqual({ kind: 'ambiguous', taskIds: ['task-a', 'task-b'], backlogVersion: 5 })
  })

  it.each([
    ['another request', response('different', 'recorded', ['task-a'])],
    ['another workspace', response(requestId, 'recorded', ['task-a'], workspaceB)],
    ['not observed with a task', response(requestId, 'not_observed', ['task-a'])],
    ['recorded with no task', response(requestId, 'recorded', [])],
    ['recorded with two tasks', response(requestId, 'recorded', ['task-a', 'task-b'])],
    ['ambiguous with one task', response(requestId, 'ambiguous', ['task-a'])],
    ['blank task', response(requestId, 'recorded', [' '])],
    ['unknown state', response(requestId, 'future', [])],
    ['invalid version', response(requestId, 'not_observed', [], workspaceA, 0)],
    ['duplicate request member', response(requestId, 'not_observed', []).replace('"creation_request_id":"request-1"',
      '"creation_request_id":"another","creation_request_id":"request-1"')],
    ['duplicate workspace member', response(requestId, 'not_observed', []).replace('"base_path":"/workspace-a"',
      '"base_path":"/foreign","base_path":"/workspace-a"')],
    ['bad JSON', '{'],
  ])('rejects %s', (_name, raw) => {
    expect(decodeTaskCreationReceipt(raw, requestId, workspaceA)).toBeNull()
  })
})

describe('original Task creation response decoding', () => {
  const body = { ok: true, creation_request_id: 'request-1', goal_id: 'goal-a', task_id: 'task-1' }
  it('requires the original request, Goal and a nonblank Task ID', () => {
    expect(decodeTaskCreationResponse(JSON.stringify(body), 'request-1', 'goal-a'))
      .toEqual({ kind: 'created', taskId: 'task-1' })
    expect(decodeTaskCreationResponse(JSON.stringify({ ...body, goal_id: null }), 'request-1', null))
      .toEqual({ kind: 'created', taskId: 'task-1' })
    expect(decodeTaskCreationResponse(JSON.stringify(body), 'another-request', 'goal-a')).toBeNull()
    expect(decodeTaskCreationResponse(JSON.stringify(body), 'request-1', null)).toBeNull()
    expect(decodeTaskCreationResponse(JSON.stringify({ ...body, task_id: '' }), 'request-1', 'goal-a')).toBeNull()
    expect(decodeTaskCreationResponse('{}', 'request-1', 'goal-a')).toBeNull()
  })
})

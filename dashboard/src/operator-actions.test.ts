import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorActionRequest } from './types'
import type { OperatorActionResult } from './api/schemas/operator-action'

const apiMocks = vi.hoisted(() => ({
  runOperatorAction: vi.fn(),
  fetchOperatorSnapshot: vi.fn(),
  fetchOperatorDigest: vi.fn(),
}))
let releaseDigestOwner: (() => Promise<void>) | undefined

// Only the transport calls are mocked. extractApiError / ApiRequestError stay
// real so the error-path tests exercise the actual summary shape the
// implementation destructures ({ message, status, ... }).
vi.mock('./api/core', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./api/core')>()
  return { ...actual, ...apiMocks }
})

// operator-actions.ts calls registerOperatorRefresh at module import time, so
// the factory must be self-contained (a hoisted const would still be in its
// temporal dead zone when the factory runs).
vi.mock('./sse-store', () => ({ registerOperatorRefresh: vi.fn() }))

// Module-private state (last-refresh timestamps, inflight promises, log id
// counter) is reset by re-importing a fresh module instance per test instead
// of exposing test backdoors from the implementation.
async function load() {
  const { acceptedExecutionWorkspace } = await import('./execution-workspace-authority')
  acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'process', workspaceRoot: '/workspace',
    connectionGeneration: 1, observerInstanceId: 'operator-test' })
  const mod = await import('./operator-actions')
  const signals = await import('./operator-signals')
  releaseDigestOwner = async () => {
    acceptedExecutionWorkspace.value = null
    await mod.refreshOperatorWorkspaceDigest({ force: true })
  }
  return { mod, signals }
}

function makeRequest(overrides: Partial<OperatorActionRequest> = {}): OperatorActionRequest {
  return {
    actor: 'vincent',
    action_type: 'keeper_restart',
    target_type: 'keeper',
    target_id: 'k1',
    payload: {},
    ...overrides,
  }
}

const executedResult: OperatorActionResult = {
  status: 'ok',
  result: 'restarted',
  tool_name: 'keeper_restart',
}

const previewResult: OperatorActionResult = {
  status: 'pending_confirm',
  confirm_required: true,
  confirm_token: 'tok-1',
  preview: { plan: 'restart keeper k1' },
}

const validSnapshot = {
  pending_confirm_envelope: {
    items: [],
    summary: {
      actor_filter: null,
      filter_active: false,
      visible_count: 0,
      total_count: 0,
      hidden_count: 0,
      hidden_actors: [],
      confirm_required_actions: [],
    },
  },
}

function validDigest(extra: Record<string, unknown> = {}) {
  return { observer_instance_id: 'operator-test', target_type: 'workspace',
    projection_diagnostics: { read_completeness: 'complete', read_error: null },
    query: { actor: 'vincent', target_type: 'workspace', effective_target_type: 'workspace',
      target_id: null, include_workers: null, default_namespace_request: false }, ...extra }
}

beforeEach(() => {
  apiMocks.runOperatorAction.mockResolvedValue(executedResult)
  apiMocks.fetchOperatorSnapshot.mockResolvedValue(validSnapshot)
  apiMocks.fetchOperatorDigest.mockResolvedValue(validDigest())
})

afterEach(async () => {
  await releaseDigestOwner?.()
  releaseDigestOwner = undefined
  vi.useRealTimers()
  vi.clearAllMocks()
  vi.resetModules()
})

describe('dispatchOperatorAction', () => {
  it('runs the action, logs an executed entry, and force-refreshes snapshot and digest', async () => {
    const { mod, signals } = await load()

    const request = makeRequest()
    const result = await mod.dispatchOperatorAction(request)

    expect(result).toEqual(executedResult)
    expect(apiMocks.runOperatorAction).toHaveBeenCalledExactlyOnceWith(request)
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)
    expect(signals.operatorActionBusy.value).toBe(false)
    expect(signals.operatorError.value).toBeNull()

    const entry = signals.operatorActionLog.value[0]
    expect(entry).toMatchObject({
      actor: 'vincent',
      action_type: 'keeper_restart',
      target_label: 'keeper:k1',
      outcome: 'executed',
      message: 'restarted',
      tool_name: 'keeper_restart',
    })
  })

  it('logs a preview entry with the stringified preview when confirmation is required', async () => {
    apiMocks.runOperatorAction.mockResolvedValue(previewResult)
    const { mod, signals } = await load()

    const result = await mod.dispatchOperatorAction(makeRequest())

    expect(result.confirm_required).toBe(true)
    const entry = signals.operatorActionLog.value[0]
    expect(entry).toMatchObject({
      outcome: 'preview',
      message: JSON.stringify({ plan: 'restart keeper k1' }),
    })
  })

  it('labels the target with target_type alone when target_id is absent', async () => {
    const { mod, signals } = await load()

    await mod.dispatchOperatorAction(makeRequest({ target_id: undefined }))

    expect(signals.operatorActionLog.value[0]?.target_label).toBe('keeper')
  })

  it('holds the busy signal during the call and releases it after', async () => {
    const { mod, signals } = await load()
    let busyDuringCall: boolean | null = null
    apiMocks.runOperatorAction.mockImplementation(() => {
      busyDuringCall = signals.operatorActionBusy.value
      return Promise.resolve(executedResult)
    })

    await mod.dispatchOperatorAction(makeRequest())

    expect(busyDuringCall).toBe(true)
    expect(signals.operatorActionBusy.value).toBe(false)
  })

  it('on failure sets the error signals, logs an error entry, rethrows, and skips refresh', async () => {
    apiMocks.runOperatorAction.mockRejectedValue(new Error('boom'))
    const { mod, signals } = await load()

    await expect(mod.dispatchOperatorAction(makeRequest())).rejects.toThrow('boom')

    expect(signals.operatorError.value).toBe('boom')
    expect(signals.operatorErrorStatus.value).toBeNull()
    expect(signals.operatorActionBusy.value).toBe(false)
    expect(signals.operatorActionLog.value[0]).toMatchObject({ outcome: 'error', message: 'boom' })
    expect(apiMocks.fetchOperatorSnapshot).not.toHaveBeenCalled()
    expect(apiMocks.fetchOperatorDigest).not.toHaveBeenCalled()
  })

  it('surfaces the HTTP status from an ApiRequestError', async () => {
    const { ApiRequestError } = await import('./api/core')
    apiMocks.runOperatorAction.mockRejectedValue(
      new ApiRequestError({ method: 'POST', path: '/api/v1/operator/action', status: 503 }),
    )
    const { mod, signals } = await load()

    await expect(mod.dispatchOperatorAction(makeRequest())).rejects.toThrow()

    expect(signals.operatorErrorStatus.value).toBe(503)
    expect(signals.operatorError.value).toContain('/api/v1/operator/action')
  })

  it('caps the action log at 20 entries, newest first', async () => {
    const { mod, signals } = await load()
    signals.operatorActionLog.value = Array.from({ length: 20 }, (_, i) => ({
      id: i + 1,
      at: '2026-06-10T00:00:00Z',
      actor: 'old',
      action_type: 'noop',
      target_label: `old-${i}`,
      outcome: 'executed' as const,
      message: 'old entry',
    }))

    await mod.dispatchOperatorAction(makeRequest())

    expect(signals.operatorActionLog.value).toHaveLength(20)
    expect(signals.operatorActionLog.value[0]?.target_label).toBe('keeper:k1')
    expect(signals.operatorActionLog.value[19]?.target_label).toBe('old-18')
  })
})

describe('background action projections', () => {
  it('returns the dispatch receipt while both projection reads remain pending', async () => {
    let finishSnapshot!: (value: unknown) => void
    let finishDigest!: (value: unknown) => void
    apiMocks.fetchOperatorSnapshot.mockImplementation(() => new Promise(resolve => { finishSnapshot = resolve }))
    apiMocks.fetchOperatorDigest.mockImplementation(() => new Promise(resolve => { finishDigest = resolve }))
    apiMocks.runOperatorAction.mockResolvedValue(previewResult)
    const { mod, signals } = await load()
    const result = await mod.dispatchOperatorAction(makeRequest(), { refresh: 'background' })
    expect(result).toEqual(previewResult)
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)
    expect(signals.operatorActionBusy.value).toBe(false)
    finishSnapshot(validSnapshot)
    finishDigest(validDigest())
    await Promise.all([mod.refreshOperatorSnapshot(), mod.refreshOperatorWorkspaceDigest()])
  })
})

it('queues one post-action read behind both held projection reads', async () => {
  let finishSnapshot!: (value: unknown) => void
  let finishDigest!: (value: unknown) => void
  apiMocks.fetchOperatorSnapshot.mockImplementationOnce(() => new Promise(resolve => { finishSnapshot = resolve }))
  apiMocks.fetchOperatorDigest.mockImplementationOnce(() => new Promise(resolve => { finishDigest = resolve }))
  const { mod, signals } = await load()
  const pending = Promise.all([mod.refreshOperatorSnapshot(), mod.refreshOperatorWorkspaceDigest()])
  await mod.dispatchOperatorAction(makeRequest(), { refresh: 'background' })
  await mod.dispatchOperatorAction(makeRequest(), { refresh: 'background' })
  expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
  expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)
  finishSnapshot({ ...validSnapshot, root: { project: 'stale' } })
  finishDigest(validDigest())
  await pending
  await vi.waitFor(() => {
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(2)
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(2)
    expect(signals.operatorSnapshot.value?.root.project).not.toBe('stale')
  })
})

describe('refreshOperatorSnapshot', () => {
  it('fetches, normalizes, and stores the snapshot while toggling the loading signal', async () => {
    apiMocks.fetchOperatorSnapshot.mockResolvedValue({
      ...validSnapshot,
      trace_id: 'trace-1',
    })
    const { mod, signals } = await load()

    await mod.refreshOperatorSnapshot()

    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
    expect(signals.operatorSnapshot.value).not.toBeNull()
    expect(signals.operatorLoading.value).toBe(false)
    expect(signals.operatorError.value).toBeNull()
  })

  it('on failure clears the previous snapshot and allows an immediate retry to refetch', async () => {
    const { mod, signals } = await load()

    await mod.refreshOperatorSnapshot()
    expect(signals.operatorSnapshot.value).not.toBeNull()
    apiMocks.fetchOperatorSnapshot.mockRejectedValueOnce(new Error('snapshot down'))
    await mod.refreshOperatorSnapshot({ force: true })

    expect(signals.operatorError.value).toBe('snapshot down')
    expect(signals.operatorErrorStatus.value).toBeNull()
    expect(signals.operatorSnapshot.value).toBeNull()
    expect(signals.operatorLoading.value).toBe(false)

    // A failed refresh must not stamp freshness — the next call refetches.
    await mod.refreshOperatorSnapshot()
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(3)
    expect(signals.operatorError.value).toBeNull()
  })

  it('skips the fetch while the previous refresh is still fresh', async () => {
    const { mod } = await load()

    await mod.refreshOperatorSnapshot()
    await mod.refreshOperatorSnapshot()

    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
  })

  it('force bypasses the freshness window', async () => {
    const { mod } = await load()

    await mod.refreshOperatorSnapshot()
    await mod.refreshOperatorSnapshot({ force: true })

    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(2)
  })

  it('refetches after the freshness TTL expires', async () => {
    vi.useFakeTimers()
    const { mod } = await load()

    await mod.refreshOperatorSnapshot()
    vi.advanceTimersByTime(1_001)
    await mod.refreshOperatorSnapshot()

    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(2)
  })

  it('dedupes concurrent refreshes onto one inflight fetch', async () => {
    let resolveFetch: ((value: unknown) => void) | null = null
    apiMocks.fetchOperatorSnapshot.mockImplementation(
      () => new Promise((resolve) => { resolveFetch = resolve }),
    )
    const { mod, signals } = await load()

    const first = mod.refreshOperatorSnapshot()
    const second = mod.refreshOperatorSnapshot()
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)

    resolveFetch!(validSnapshot)
    await Promise.all([first, second])
    expect(signals.operatorSnapshot.value).not.toBeNull()
  })
})

describe('refreshOperatorWorkspaceDigest', () => {
  it('fetches the workspace digest and stores the normalized result', async () => {
    apiMocks.fetchOperatorDigest.mockResolvedValue(validDigest({ trace_id: 'digest-1' }))
    const { mod, signals } = await load()

    await mod.refreshOperatorWorkspaceDigest()

    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledExactlyOnceWith({ targetType: 'workspace', signal: expect.any(AbortSignal) })
    expect(signals.operatorWorkspaceDigest.value).not.toBeNull()
    expect(signals.operatorDigestLoading.value).toBe(false)
  })

  it('on failure records the digest error summary without touching the snapshot error', async () => {
    apiMocks.fetchOperatorDigest.mockRejectedValueOnce(new Error('digest down'))
    const { mod, signals } = await load()

    await mod.refreshOperatorWorkspaceDigest()

    expect(signals.operatorDigestError.value).toBe('digest down')
    expect(signals.operatorDigestErrorStatus.value).toBeNull()
    expect(signals.operatorError.value).toBeNull()
    expect(signals.operatorDigestLoading.value).toBe(false)
  })

  it('skips while fresh and refetches with force', async () => {
    const { mod } = await load()

    await mod.refreshOperatorWorkspaceDigest()
    await mod.refreshOperatorWorkspaceDigest()
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)

    await mod.refreshOperatorWorkspaceDigest({ force: true })
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(2)
  })

  it('dedupes concurrent digest refreshes onto one inflight fetch', async () => {
    let resolveFetch: ((value: unknown) => void) | null = null
    apiMocks.fetchOperatorDigest.mockImplementation(
      () => new Promise((resolve) => { resolveFetch = resolve }),
    )
    const { mod, signals } = await load()

    const first = mod.refreshOperatorWorkspaceDigest()
    const second = mod.refreshOperatorWorkspaceDigest()
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)

    resolveFetch!(validDigest())
    await Promise.all([first, second])
    expect(signals.operatorWorkspaceDigest.value).not.toBeNull()
  })
})

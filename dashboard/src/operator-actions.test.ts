import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorActionRequest } from './types'
import type { OperatorActionResult } from './api/schemas/operator-action'

const apiMocks = vi.hoisted(() => ({
  runOperatorAction: vi.fn(),
  confirmOperatorAction: vi.fn(),
  fetchOperatorSnapshot: vi.fn(),
  fetchOperatorDigest: vi.fn(),
}))

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
  const mod = await import('./operator-actions')
  const signals = await import('./operator-signals')
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

beforeEach(() => {
  apiMocks.runOperatorAction.mockResolvedValue(executedResult)
  apiMocks.confirmOperatorAction.mockResolvedValue(executedResult)
  apiMocks.fetchOperatorSnapshot.mockResolvedValue(validSnapshot)
  apiMocks.fetchOperatorDigest.mockResolvedValue({})
})

afterEach(() => {
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

describe('confirmOperatorPendingAction', () => {
  it('confirms with the default decision and logs a confirmed entry', async () => {
    const { mod, signals } = await load()

    const result = await mod.confirmOperatorPendingAction('vincent', 'tok-1')

    expect(result).toEqual(executedResult)
    expect(apiMocks.confirmOperatorAction).toHaveBeenCalledExactlyOnceWith('vincent', 'tok-1', 'confirm')
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)
    expect(signals.operatorActionLog.value[0]).toMatchObject({
      actor: 'vincent',
      action_type: 'confirm',
      target_label: 'tok-1',
      outcome: 'confirmed',
    })
  })

  it('passes an explicit deny decision through to the API and the log', async () => {
    const { mod, signals } = await load()

    await mod.confirmOperatorPendingAction('vincent', 'tok-1', 'deny')

    expect(apiMocks.confirmOperatorAction).toHaveBeenCalledExactlyOnceWith('vincent', 'tok-1', 'deny')
    expect(signals.operatorActionLog.value[0]?.action_type).toBe('deny')
  })

  it('on failure sets the error signals, logs an error entry, and rethrows', async () => {
    apiMocks.confirmOperatorAction.mockRejectedValue(new Error('denied upstream'))
    const { mod, signals } = await load()

    await expect(mod.confirmOperatorPendingAction('vincent', 'tok-1')).rejects.toThrow('denied upstream')

    expect(signals.operatorError.value).toBe('denied upstream')
    expect(signals.operatorActionBusy.value).toBe(false)
    expect(signals.operatorActionLog.value[0]).toMatchObject({ outcome: 'error', target_label: 'tok-1' })
  })
})

describe('background action projections', () => {
  it.each(['dispatch', 'confirm'] as const)('returns %s receipt while both projection reads remain pending', async operation => {
    let finishSnapshot!: (value: unknown) => void
    let finishDigest!: (value: unknown) => void
    apiMocks.fetchOperatorSnapshot.mockImplementation(() => new Promise(resolve => { finishSnapshot = resolve }))
    apiMocks.fetchOperatorDigest.mockImplementation(() => new Promise(resolve => { finishDigest = resolve }))
    apiMocks.runOperatorAction.mockResolvedValue(previewResult)
    const { mod, signals } = await load()
    const result = operation === 'dispatch'
      ? await mod.dispatchOperatorAction(makeRequest(), { refresh: 'background' })
      : await mod.confirmOperatorPendingAction('vincent', 'tok-1', 'confirm', { refresh: 'background' })
    expect(result).toEqual(operation === 'dispatch' ? previewResult : executedResult)
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)
    expect(signals.operatorActionBusy.value).toBe(false)
    finishSnapshot(validSnapshot)
    finishDigest({})
    await Promise.all([mod.refreshOperatorSnapshot(), mod.refreshOperatorWorkspaceDigest()])
  })
})

it('queues one post-confirmation read behind both held projection reads', async () => {
  let finishSnapshot!: (value: unknown) => void
  let finishDigest!: (value: unknown) => void
  apiMocks.fetchOperatorSnapshot.mockImplementationOnce(() => new Promise(resolve => { finishSnapshot = resolve }))
  apiMocks.fetchOperatorDigest.mockImplementationOnce(() => new Promise(resolve => { finishDigest = resolve }))
  const { mod, signals } = await load()
  const pending = Promise.all([mod.refreshOperatorSnapshot(), mod.refreshOperatorWorkspaceDigest()])
  await mod.confirmOperatorPendingAction('vincent', 'tok-1', 'confirm', { refresh: 'background' })
  await mod.confirmOperatorPendingAction('vincent', 'tok-2', 'confirm', { refresh: 'background' })
  expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(1)
  expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(1)
  finishSnapshot({ ...validSnapshot, root: { paused: true } })
  finishDigest({})
  await pending
  await vi.waitFor(() => {
    expect(apiMocks.fetchOperatorSnapshot).toHaveBeenCalledTimes(2)
    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledTimes(2)
    expect(signals.operatorSnapshot.value?.root.paused).not.toBe(true)
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
  it('fetches the namespace digest and stores the normalized result', async () => {
    apiMocks.fetchOperatorDigest.mockResolvedValue({ trace_id: 'digest-1' })
    const { mod, signals } = await load()

    await mod.refreshOperatorWorkspaceDigest()

    expect(apiMocks.fetchOperatorDigest).toHaveBeenCalledExactlyOnceWith({ targetType: 'namespace' })
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

    resolveFetch!({})
    await Promise.all([first, second])
    expect(signals.operatorWorkspaceDigest.value).not.toBeNull()
  })
})

describe('overlapping operator action lifetime', () => {
  it.each(['success', 'failure'] as const)('keeps another action busy after the first %s', async (outcome) => {
    const { mod, signals } = await load()
    let resolveFirst!: (result: OperatorActionResult) => void
    let rejectFirst!: (error: Error) => void
    let resolveSecond!: (result: OperatorActionResult) => void
    apiMocks.runOperatorAction.mockReturnValue(new Promise<OperatorActionResult>((resolve, reject) => {
      resolveFirst = resolve
      rejectFirst = reject
    }))
    apiMocks.confirmOperatorAction.mockReturnValue(new Promise<OperatorActionResult>(resolve => { resolveSecond = resolve }))
    const first = mod.dispatchOperatorAction(makeRequest()).catch(error => error)
    const second = mod.confirmOperatorPendingAction('vincent', 'second-token')
    expect(signals.operatorActionBusy.value).toBe(true)
    try {
      if (outcome === 'failure') rejectFirst(new Error('first failed'))
      else resolveFirst(executedResult)
      await first
      expect(signals.operatorActionBusy.value).toBe(true)
    } finally {
      resolveSecond(executedResult)
      await second
    }
    expect(signals.operatorActionBusy.value).toBe(false)
  })
})

describe('operator action credential publication ownership', () => {
  it.each([
    ['dispatch', 'success'], ['dispatch', 'failure'],
    ['confirm', 'success'], ['confirm', 'failure'],
  ] as const)('does not publish previous credential %s %s effects', async (action, outcome) => {
    const { mod, signals } = await load()
    const { setStoredToken, clearStoredToken } = await import('./api/core')
    setStoredToken('synthetic-action-owner-a')
    let resolve!: (result: OperatorActionResult) => void
    let reject!: (error: Error) => void
    const deferred = new Promise<OperatorActionResult>((done, fail) => { resolve = done; reject = fail })
    if (action === 'dispatch') apiMocks.runOperatorAction.mockReturnValue(deferred)
    else apiMocks.confirmOperatorAction.mockReturnValue(deferred)
    const pending = (action === 'dispatch'
      ? mod.dispatchOperatorAction(makeRequest())
      : mod.confirmOperatorPendingAction('vincent', 'old-owner-token')).catch(error => error)
    setStoredToken('synthetic-action-owner-b')
    signals.operatorError.value = 'current owner error'
    signals.operatorErrorStatus.value = 409
    try {
      if (outcome === 'success') resolve(executedResult)
      else reject(new Error('previous owner failure'))
      const receipt = await pending
      expect(signals.operatorActionLog.value).toEqual([])
      expect(signals.operatorError.value).toBe('current owner error')
      expect(signals.operatorErrorStatus.value).toBe(409)
      expect(apiMocks.fetchOperatorSnapshot).not.toHaveBeenCalled()
      expect(apiMocks.fetchOperatorDigest).not.toHaveBeenCalled()
      if (outcome === 'success') expect(receipt).toEqual(executedResult)
      else expect(receipt.message).toBe('previous owner failure')
    } finally {
      clearStoredToken()
    }
  })
})

describe('operator receipt observer interleaving', () => {
  it.each(['dispatch', 'confirm'] as const)('does not refresh a replacement account after %s log observers run', async (action) => {
    const { mod, signals } = await load()
    const { setStoredToken, clearStoredToken } = await import('./api/core')
    const { effect } = await import('@preact/signals')
    setStoredToken('synthetic-log-owner-a')
    const dispose = effect(() => {
      if (signals.operatorActionLog.value.length > 0) setStoredToken('synthetic-log-owner-b')
    })
    try {
      const result = action === 'dispatch'
        ? await mod.dispatchOperatorAction(makeRequest())
        : await mod.confirmOperatorPendingAction('vincent', 'owned-confirm-token')
      expect(result).toEqual(executedResult)
      expect(apiMocks.fetchOperatorSnapshot).not.toHaveBeenCalled()
      expect(apiMocks.fetchOperatorDigest).not.toHaveBeenCalled()
    } finally {
      dispose()
      clearStoredToken()
    }
  })
})

describe('operator error observer interleaving', () => {
  it.each([['dispatch', 'error'], ['dispatch', 'status'], ['confirm', 'error'], ['confirm', 'status']] as const)('preserves replacement account state after %s %s observers run', async (action, field) => {
    const { mod, signals } = await load()
    const { setStoredToken, clearStoredToken } = await import('./api/core')
    const { effect } = await import('@preact/signals')
    setStoredToken('synthetic-error-publication-a')
    const { ApiRequestError } = await import('./api/core')
    const oldFailure = field === 'status'
      ? new ApiRequestError({ method: 'POST', path: '/api/v1/operator/action', status: 503 })
      : new Error('old admitted failure')
    if (action === 'dispatch') apiMocks.runOperatorAction.mockRejectedValue(oldFailure)
    else apiMocks.confirmOperatorAction.mockRejectedValue(oldFailure)
    const dispose = effect(() => {
      if (field === 'error' ? signals.operatorError.value === oldFailure.message : signals.operatorErrorStatus.value === 503) {
        setStoredToken('synthetic-error-publication-b')
        signals.operatorError.value = 'replacement account error'
        signals.operatorErrorStatus.value = 409
        signals.operatorActionLog.value = []
      }
    })
    try {
      const pending = action === 'dispatch'
        ? mod.dispatchOperatorAction(makeRequest())
        : mod.confirmOperatorPendingAction('vincent', 'old-confirm-token')
      await expect(pending).rejects.toBe(oldFailure)
      expect(signals.operatorError.value).toBe('replacement account error')
      expect(signals.operatorErrorStatus.value).toBe(409)
      expect(signals.operatorActionLog.value).toEqual([])
    } finally {
      dispose()
      clearStoredToken()
    }
  })
})

describe('operator action initial observer admission', () => {
  it.each([
    ['dispatch', 'busy'], ['dispatch', 'error'], ['dispatch', 'status'],
    ['confirm', 'busy'], ['confirm', 'error'], ['confirm', 'status'],
  ] as const)('does not admit %s under credentials changed by its %s observer', async (action, field) => {
    const { mod, signals } = await load()
    const { setStoredToken, clearStoredToken } = await import('./api/core')
    const { effect } = await import('@preact/signals')
    setStoredToken('synthetic-initial-owner-a')
    signals.operatorError.value = 'initial error'
    signals.operatorErrorStatus.value = 503
    const dispose = effect(() => {
      const pending = signals.operatorActionBusy.value
      const changed = field === 'busy' ? pending
        : field === 'error' ? signals.operatorError.value === null
        : signals.operatorErrorStatus.value === null
      if (pending && changed) {
        setStoredToken('synthetic-initial-owner-b')
        signals.operatorError.value = 'replacement initial error'
        signals.operatorErrorStatus.value = 409
      }
    })
    try {
      const pending = action === 'dispatch'
        ? mod.dispatchOperatorAction(makeRequest())
        : mod.confirmOperatorPendingAction('vincent', 'previous-owner-confirm')
      const outcome = await Promise.allSettled([pending])
      expect(apiMocks.runOperatorAction).not.toHaveBeenCalled()
      expect(apiMocks.confirmOperatorAction).not.toHaveBeenCalled()
      expect(outcome[0].status).toBe('rejected')
      if (outcome[0].status === 'rejected') {
        expect(outcome[0].reason).toBeInstanceOf(mod.OperatorActionAuthenticationSupersededError)
      }
      expect(signals.operatorError.value).toBe('replacement initial error')
      expect(signals.operatorErrorStatus.value).toBe(409)
      expect(signals.operatorActionBusy.value).toBe(false)
      expect(signals.operatorActionLog.value).toEqual([])
    } finally {
      dispose()
      clearStoredToken()
    }
  })
})

describe('operator refresh credential completion ownership', () => {
  it.each([['snapshot', 'success'], ['snapshot', 'failure'], ['digest', 'success'], ['digest', 'failure']] as const)(
    'does not publish previous credential %s %s completion', async (kind, outcome) => {
      const { mod, signals } = await load()
      const { setStoredToken, clearStoredToken } = await import('./api/core')
      setStoredToken('synthetic-refresh-owner-a')
      let resolve!: (value: unknown) => void
      let reject!: (error: Error) => void
      const deferred = new Promise((done, fail) => { resolve = done; reject = fail })
      if (kind === 'snapshot') apiMocks.fetchOperatorSnapshot.mockReturnValue(deferred)
      else apiMocks.fetchOperatorDigest.mockReturnValue(deferred)
      const pending = kind === 'snapshot' ? mod.refreshOperatorSnapshot() : mod.refreshOperatorWorkspaceDigest()
      setStoredToken('synthetic-refresh-owner-b')
      const loading = kind === 'snapshot' ? signals.operatorLoading : signals.operatorDigestLoading
      const error = kind === 'snapshot' ? signals.operatorError : signals.operatorDigestError
      const status = kind === 'snapshot' ? signals.operatorErrorStatus : signals.operatorDigestErrorStatus
      loading.value = true
      error.value = 'replacement refresh error'
      status.value = 409
      try {
        if (outcome === 'success') resolve(kind === 'snapshot' ? validSnapshot : { trace_id: 'old-digest' })
        else reject(new Error('old refresh failed'))
        await pending
        expect(loading.value).toBe(true)
        expect(error.value).toBe('replacement refresh error')
        expect(status.value).toBe(409)
        expect(kind === 'snapshot' ? signals.operatorSnapshot.value : signals.operatorWorkspaceDigest.value).toBeNull()
      } finally {
        clearStoredToken()
      }
    },
  )
})

describe('operator refresh replacement and queued ownership', () => {
  it.each(['snapshot', 'digest'] as const)('keeps the replacement %s read when the old read and followup finish', async (kind) => {
    const { mod, signals } = await load()
    const { setStoredToken, clearStoredToken } = await import('./api/core')
    setStoredToken('synthetic-queued-refresh-a')
    let finishOld!: (value: unknown) => void
    let finishCurrent!: (value: unknown) => void
    const transport = kind === 'snapshot' ? apiMocks.fetchOperatorSnapshot : apiMocks.fetchOperatorDigest
    transport.mockReturnValueOnce(new Promise(resolve => { finishOld = resolve }))
      .mockReturnValueOnce(new Promise(resolve => { finishCurrent = resolve }))
    const refresh = kind === 'snapshot' ? mod.refreshOperatorSnapshot : mod.refreshOperatorWorkspaceDigest
    const old = refresh()
    const oldForced = refresh({ force: true })
    setStoredToken('synthetic-queued-refresh-b')
    const current = refresh()
    const loading = kind === 'snapshot' ? signals.operatorLoading : signals.operatorDigestLoading
    try {
      expect(transport).toHaveBeenCalledTimes(2)
      finishOld(kind === 'snapshot' ? validSnapshot : {})
      await Promise.all([old, oldForced])
      expect(loading.value).toBe(true)
      const coalesced = refresh()
      expect(transport).toHaveBeenCalledTimes(2)
      finishCurrent(kind === 'snapshot' ? validSnapshot : {})
      await Promise.all([current, coalesced])
      expect(loading.value).toBe(false)
      expect(kind === 'snapshot' ? signals.operatorSnapshot.value : signals.operatorWorkspaceDigest.value).not.toBeNull()
    } finally {
      finishOld(kind === 'snapshot' ? validSnapshot : {})
      finishCurrent(kind === 'snapshot' ? validSnapshot : {})
      await Promise.all([old, oldForced, current])
      clearStoredToken()
    }
  })
})

describe('operator refresh observer failure cleanup', () => {
  it.each(['snapshot', 'digest'] as const)('releases %s operations and queued work after a cleanup observer throws', async (kind) => {
    const { mod, signals } = await load()
    const { effect } = await import('@preact/signals')
    const loading = kind === 'snapshot' ? signals.operatorLoading : signals.operatorDigestLoading
    const refresh = kind === 'snapshot' ? mod.refreshOperatorSnapshot : mod.refreshOperatorWorkspaceDigest
    const transport = kind === 'snapshot' ? apiMocks.fetchOperatorSnapshot : apiMocks.fetchOperatorDigest
    let finishFirst!: (value: unknown) => void
    let finishSecond!: (value: unknown) => void
    transport.mockReturnValueOnce(new Promise(resolve => { finishFirst = resolve }))
      .mockReturnValueOnce(new Promise(resolve => { finishSecond = resolve }))
    let started = false
    let thrown = false
    const observerFailure = new Error('cleanup observer failed')
    const dispose = effect(() => {
      if (loading.value) started = true
      else if (started && !thrown) { thrown = true; throw observerFailure }
    })
    const first = refresh()
    const queued = refresh({ force: true })
    try {
      finishFirst(kind === 'snapshot' ? validSnapshot : {})
      const old = await Promise.allSettled([first, queued])
      expect(old.every(result => result.status === 'rejected')).toBe(true)
      dispose()
      const second = refresh({ force: true })
      const nextQueued = refresh({ force: true })
      const secondOutcome = second.catch(error => error)
      const nextOutcome = nextQueued.catch(error => error)
      try {
        expect(transport).toHaveBeenCalledTimes(2)
      } finally {
        if (typeof finishSecond === 'function') finishSecond(kind === 'snapshot' ? validSnapshot : {})
        await Promise.all([secondOutcome, nextOutcome])
      }
      expect(transport).toHaveBeenCalledTimes(3)
      expect(loading.value).toBe(false)
    } finally {
      dispose()
      finishFirst(kind === 'snapshot' ? validSnapshot : {})
      await Promise.allSettled([first, queued])
    }
  })
})

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type {
  OperatorActionRequest,
  OperatorActionResult,
  RefreshOptions,
} from './types'
import type { Mock } from 'vitest'

// ─── Module-level mocks ───────────────────────────────────────────

const mockRunOpAction = vi.fn<(...args: unknown[]) => unknown>()
const mockConfirmOpAction = vi.fn<(...args: unknown[]) => unknown>()
const mockFetchSnapshot = vi.fn<(...args: unknown[]) => unknown>()
const mockFetchDigest = vi.fn<(...args: unknown[]) => unknown>()
const mockExtractApiError = vi.fn<(...args: unknown[]) => unknown>()
const mockNormalizeSnapshot = vi.fn<(...args: unknown[]) => unknown>()
const mockNormalizeDigest = vi.fn<(...args: unknown[]) => unknown>()
const mockRegisterRefresh = vi.fn<(...args: unknown[]) => unknown>()

vi.mock('./api/core', () => ({
  runOperatorAction: (...args: unknown[]) => mockRunOpAction(...args),
  confirmOperatorAction: (...args: unknown[]) => mockConfirmOpAction(...args),
  fetchOperatorSnapshot: (...args: unknown[]) => mockFetchSnapshot(...args),
  fetchOperatorDigest: (...args: unknown[]) => mockFetchDigest(...args),
  extractApiError: (...args: unknown[]) => mockExtractApiError(...args),
}))

vi.mock('./operator-normalizers', () => ({
  normalizeOperatorSnapshot: (...args: unknown[]) => mockNormalizeSnapshot(...args),
  normalizeOperatorDigest: (...args: unknown[]) => mockNormalizeDigest(...args),
}))

vi.mock('./sse-store', () => ({
  registerOperatorRefresh: (...args: unknown[]) => mockRegisterRefresh(...args),
}))

// ─── Import after mocks are hoisted ───────────────────────────────

import {
  dispatchOperatorAction,
  tryConfirmLastAction,
  refreshOperatorSnapshot,
  refreshOperatorWorkspaceDigest,
} from './operator-actions'
import {
  operatorSnapshot,
  operatorWorkspaceDigest,
  operatorLoading,
  operatorError,
  operatorErrorStatus,
  operatorDigestLoading,
  operatorDigestError,
  operatorDigestErrorStatus,
  operatorActionBusy,
  operatorActionLog,
} from './operator-signals'

// ─── Helpers ──────────────────────────────────────────────────────

function makeRequest(overrides?: Partial<OperatorActionRequest>): OperatorActionRequest {
  return {
    actor: 'test-keeper',
    action_type: 'pause',
    target_type: 'agent',
    target_id: 'sangsu',
    payload: {},
    ...overrides,
  }
}

function makeResult(overrides?: Partial<OperatorActionResult>): OperatorActionResult {
  return {
    outcome: 'preview' as const,
    preview: 'test preview',
    confirm_required: true,
    pending_confirm_id: 'c-1',
    ...overrides,
  }
}

/** Reset all module-level mutable state by re-importing fresh.
 *  Because vitest caches modules, we reset the mutable vars by
 *  directly clearing the signals and module-level state via the
 *  before/after hooks. */
beforeEach(() => {
  vi.useFakeTimers()
  // Reset signals
  operatorSnapshot.value = null
  operatorWorkspaceDigest.value = null
  operatorLoading.value = false
  operatorError.value = null
  operatorErrorStatus.value = null
  operatorDigestLoading.value = false
  operatorDigestError.value = null
  operatorDigestErrorStatus.value = null
  operatorActionBusy.value = false
  operatorActionLog.value = []
  // Reset mocks
  vi.clearAllMocks()
})

afterEach(() => {
  vi.useRealTimers()
})

// ─── dispatchOperatorAction ───────────────────────────────────────

describe('dispatchOperatorAction', () => {
  it('calls runOperatorAction and returns the result', async () => {
    const result = makeResult({ outcome: 'executed', confirm_required: false })
    mockRunOpAction.mockResolvedValue(result)

    const actual = await dispatchOperatorAction(makeRequest())

    expect(actual).toEqual(result)
    expect(mockRunOpAction).toHaveBeenCalledTimes(1)
  })

  it('appends a log entry on success', async () => {
    const result = makeResult({ outcome: 'executed', confirm_required: false, result: 'done' })
    mockRunOpAction.mockResolvedValue(result)

    await dispatchOperatorAction(makeRequest())

    expect(operatorActionLog.value.length).toBeGreaterThanOrEqual(1)
    const entry = operatorActionLog.value[0]
    expect(entry.actor).toBe('test-keeper')
    expect(entry.action_type).toBe('pause')
    expect(entry.outcome).toBe('executed')
    expect(entry.message).toContain('done')
  })

  it('sets operatorActionBusy during the call', async () => {
    let resolvePromise!: (v: OperatorActionResult) => void
    mockRunOpAction.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))

    const promise = dispatchOperatorAction(makeRequest())
    expect(operatorActionBusy.value).toBe(true)
    resolvePromise(makeResult())
    await promise
    expect(operatorActionBusy.value).toBe(false)
  })

  it('appends a log entry with outcome "preview" when confirm_required is true', async () => {
    const result = makeResult({ outcome: 'preview', confirm_required: true, preview: 'needs ok' })
    mockRunOpAction.mockResolvedValue(result)

    await dispatchOperatorAction(makeRequest())

    const entry = operatorActionLog.value[0]
    expect(entry.outcome).toBe('preview')
    expect(entry.message).toContain('needs ok')
  })

  it('refreshes snapshot and digest after successful action', async () => {
    mockRunOpAction.mockResolvedValue(makeResult({ outcome: 'executed' }))
    mockFetchSnapshot.mockResolvedValue({ raw: 'snap' })
    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap' })
    mockFetchDigest.mockResolvedValue({ raw: 'digest' })
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest' })

    await dispatchOperatorAction(makeRequest())

    // Should have triggered at least one refresh call (snapshot or digest)
    expect(mockFetchSnapshot.mock.calls.length + mockFetchDigest.mock.calls.length).toBeGreaterThan(0)
  })
})

// ─── tryConfirmLastAction ─────────────────────────────────────────

describe('tryConfirmLastAction', () => {
  it('calls confirmOperatorAction and returns the result', async () => {
    const result = makeResult({ outcome: 'confirmed', confirm_required: false })
    mockConfirmOpAction.mockResolvedValue(result)

    const actual = await tryConfirmLastAction()

    expect(actual).toEqual(result)
    expect(mockConfirmOpAction).toHaveBeenCalledTimes(1)
  })

  it('returns null when no last action to confirm', async () => {
    mockConfirmOpAction.mockResolvedValue(null)

    const actual = await tryConfirmLastAction()

    expect(actual).toBeNull()
  })

  it('sets operatorActionBusy during the call', async () => {
    let resolvePromise!: (v: OperatorActionResult) => void
    mockConfirmOpAction.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))

    const promise = tryConfirmLastAction()
    expect(operatorActionBusy.value).toBe(true)
    resolvePromise(makeResult())
    await promise
    expect(operatorActionBusy.value).toBe(false)
  })

  it('appends a log entry on successful confirmation', async () => {
    mockConfirmOpAction.mockResolvedValue(makeResult({ outcome: 'confirmed', confirm_required: false, result: 'confirmed ok' }))

    await tryConfirmLastAction()

    const entry = operatorActionLog.value[0]
    expect(entry).toBeDefined()
    expect(entry.outcome).toBe('confirmed')
  })

  it('does not append log when result is null', async () => {
    mockConfirmOpAction.mockResolvedValue(null)

    await tryConfirmLastAction()

    expect(operatorActionLog.value.length).toBe(0)
  })

  it('refreshes snapshot and digest after successful confirmation', async () => {
    mockConfirmOpAction.mockResolvedValue(makeResult({ outcome: 'confirmed' }))
    mockFetchSnapshot.mockResolvedValue({ raw: 'snap' })
    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap' })
    mockFetchDigest.mockResolvedValue({ raw: 'digest' })
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest' })

    await tryConfirmLastAction()

    expect(mockFetchSnapshot.mock.calls.length + mockFetchDigest.mock.calls.length).toBeGreaterThan(0)
  })
})

// ─── refreshOperatorSnapshot ──────────────────────────────────────

describe('refreshOperatorSnapshot', () => {
  it('fetches snapshot and updates signal', async () => {
    mockFetchSnapshot.mockResolvedValue({ some: 'data' })
    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap', status: 'active' })

    await refreshOperatorSnapshot()

    expect(operatorSnapshot.value).toEqual({ normalized: 'snap', status: 'active' })
    expect(operatorLoading.value).toBe(false)
  })

  it('sets loading and error signals', async () => {
    mockFetchSnapshot.mockRejectedValue(new Error('network error'))
    mockExtractApiError.mockReturnValue('network error')

    await refreshOperatorSnapshot()

    expect(operatorLoading.value).toBe(false)
    expect(operatorError.value).toBe('network error')
    expect(operatorSnapshot.value).toBeNull()
  })

  it('skips fetch when recent and not forced', async () => {
    mockFetchSnapshot.mockResolvedValue({ some: 'data' })
    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap' })

    // First call populates
    await refreshOperatorSnapshot()
    expect(mockFetchSnapshot).toHaveBeenCalledTimes(1)

    // Second call within TTL should skip
    await refreshOperatorSnapshot()
    expect(mockFetchSnapshot).toHaveBeenCalledTimes(1) // not called again
  })

  it('re-fetches when forced', async () => {
    mockFetchSnapshot.mockResolvedValue({ some: 'data' })
    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap' })

    await refreshOperatorSnapshot()
    expect(mockFetchSnapshot).toHaveBeenCalledTimes(1)

    // Advance time past TTL, then force
    vi.advanceTimersByTime(100_000)
    await refreshOperatorSnapshot({ force: true })
    expect(mockFetchSnapshot).toHaveBeenCalledTimes(2)
  })

  it('re-fetches after TTL elapses', async () => {
    mockFetchSnapshot.mockResolvedValue({ some: 'data' })
    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap' })

    await refreshOperatorSnapshot()
    expect(mockFetchSnapshot).toHaveBeenCalledTimes(1)

    // Advance past TTL
    vi.advanceTimersByTime(100_000)
    await refreshOperatorSnapshot()
    expect(mockFetchSnapshot).toHaveBeenCalledTimes(2)
  })

  it('deduplicates concurrent calls via inflight promise', async () => {
    let resolvePromise!: (v: unknown) => void
    mockFetchSnapshot.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))

    mockNormalizeSnapshot.mockReturnValue({ normalized: 'snap' })

    const p1 = refreshOperatorSnapshot()
    const p2 = refreshOperatorSnapshot() // should reuse inflight

    resolvePromise({ data: 'ok' })
    await Promise.all([p1, p2])

    expect(mockFetchSnapshot).toHaveBeenCalledTimes(1)
  })
})

// ─── refreshOperatorWorkspaceDigest ───────────────────────────────

describe('refreshOperatorWorkspaceDigest', () => {
  it('fetches digest and updates signal', async () => {
    mockFetchDigest.mockResolvedValue({ workspace: 'data' })
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest', summary: 'workspace active' })

    await refreshOperatorWorkspaceDigest()

    expect(operatorWorkspaceDigest.value).toEqual({ normalized: 'digest', summary: 'workspace active' })
    expect(operatorDigestLoading.value).toBe(false)
  })

  it('sets loading and error signals on failure', async () => {
    mockFetchDigest.mockRejectedValue(new Error('digest error'))
    mockExtractApiError.mockReturnValue('digest error')

    await refreshOperatorWorkspaceDigest()

    expect(operatorDigestLoading.value).toBe(false)
    expect(operatorDigestError.value).toBe('digest error')
    expect(operatorWorkspaceDigest.value).toBeNull()
  })

  it('skips fetch when recent and not forced', async () => {
    mockFetchDigest.mockResolvedValue({ workspace: 'data' })
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest' })

    await refreshOperatorWorkspaceDigest()
    expect(mockFetchDigest).toHaveBeenCalledTimes(1)

    await refreshOperatorWorkspaceDigest()
    expect(mockFetchDigest).toHaveBeenCalledTimes(1)
  })

  it('re-fetches when forced', async () => {
    mockFetchDigest.mockResolvedValue({ workspace: 'data' })
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest' })

    await refreshOperatorWorkspaceDigest()
    expect(mockFetchDigest).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(100_000)
    await refreshOperatorWorkspaceDigest({ force: true })
    expect(mockFetchDigest).toHaveBeenCalledTimes(2)
  })

  it('re-fetches after TTL elapses', async () => {
    mockFetchDigest.mockResolvedValue({ workspace: 'data' })
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest' })

    await refreshOperatorWorkspaceDigest()
    expect(mockFetchDigest).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(100_000)
    await refreshOperatorWorkspaceDigest()
    expect(mockFetchDigest).toHaveBeenCalledTimes(2)
  })

  it('deduplicates concurrent calls via inflight promise', async () => {
    let resolvePromise!: (v: unknown) => void
    mockFetchDigest.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))
    mockNormalizeDigest.mockReturnValue({ normalized: 'digest' })

    const p1 = refreshOperatorWorkspaceDigest()
    const p2 = refreshOperatorWorkspaceDigest()

    resolvePromise({ workspace: 'ok' })
    await Promise.all([p1, p2])

    expect(mockFetchDigest).toHaveBeenCalledTimes(1)
  })
})

// ─── Error handling ───────────────────────────────────────────────

describe('error handling', () => {
  it('dispatchOperatorAction preserves operatorActionBusy on error', async () => {
    mockRunOpAction.mockRejectedValue(new Error('boom'))

    await expect(dispatchOperatorAction(makeRequest())).rejects.toThrow('boom')
    expect(operatorActionBusy.value).toBe(false)
  })

  it('tryConfirmLastAction preserves operatorActionBusy on error', async () => {
    mockConfirmOpAction.mockRejectedValue(new Error('confirm boom'))

    await expect(tryConfirmLastAction()).rejects.toThrow('confirm boom')
    expect(operatorActionBusy.value).toBe(false)
  })
})
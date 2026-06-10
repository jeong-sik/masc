import { describe, it, expect, vi, beforeEach } from 'vitest'

// ─── Module-level mocks ───────────────────────────────────────────

const mockCallMcpTool = vi.fn<(...args: unknown[]) => unknown>()
const mockRunOperatorAction = vi.fn<(...args: unknown[]) => unknown>()
const mockSendKeeperMessageDetailed = vi.fn<(...args: unknown[]) => unknown>()
const mockStreamKeeperMessage = vi.fn<(...args: unknown[]) => unknown>()
const mockInvalidateDashboardCache = vi.fn<(...args: unknown[]) => unknown>()
const mockRefreshDashboard = vi.fn<(...args: unknown[]) => unknown>()

vi.mock('./api/mcp', () => ({
  callMcpTool: (...args: unknown[]) => mockCallMcpTool(...args),
}))

vi.mock('./api/core', () => ({
  runOperatorAction: (...args: unknown[]) => mockRunOperatorAction(...args),
}))

vi.mock('./api/keeper', () => ({
  sendKeeperMessageDetailed: (...args: unknown[]) => mockSendKeeperMessageDetailed(...args),
  streamKeeperMessage: (...args: unknown[]) => mockStreamKeeperMessage(...args),
}))

vi.mock('./store', () => ({
  invalidateDashboardCache: (...args: unknown[]) => mockInvalidateDashboardCache(...args),
  refreshDashboard: (...args: unknown[]) => mockRefreshDashboard(...args),
}))

// ─── Tested module imports ────────────────────────────────────────

import {
  selectKeeper,
  dispatchKeeperInterjectAction,
  hydrateKeeperStatus,
  loadFullKeeperHistory,
  sendKeeperThreadMessage,
  probeKeeperRuntime,
  recoverKeeperRuntime,
} from './keeper-actions'

import {
  activeKeeperName,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperActionErrors,
  keeperSending,
  keeperStatusDetails,
  keeperThreads,
  keeperStreamStartedAt,
} from './keeper-state'

import type {
  KeeperStatusDetail,
  KeeperDiagnostic,
} from './types'

// ─── Helpers ──────────────────────────────────────────────────────

function mockStatusText(overrides?: Record<string, unknown>): string {
  return JSON.stringify({
    name: 'sangsu',
    status: 'active',
    uptime_seconds: 3600,
    memory_turns: 42,
    ...overrides,
  })
}

function mockDiagnostic(): KeeperDiagnostic {
  return {
    status: 'active',
    uptime_seconds: 120,
    memory_turns: 10,
    context_ratio: 0.3,
    error_count: 0,
    tag_summary: null,
    checklist_summary: null,
  } as KeeperDiagnostic
}

beforeEach(() => {
  vi.useFakeTimers()
  // Reset signals
  activeKeeperName.value = null
  keeperHydrating.value = {}
  keeperProbing.value = {}
  keeperRecovering.value = {}
  keeperActionErrors.value = {}
  keeperSending.value = {}
  keeperStatusDetails.value = {}
  keeperThreads.value = {}
  keeperStreamStartedAt.value = {}
  // Reset mocks
  vi.clearAllMocks()
})

afterEach(() => {
  vi.useRealTimers()
})

// ─── selectKeeper ─────────────────────────────────────────────────

describe('selectKeeper', () => {
  it('sets activeKeeperName and refreshes dashboard', () => {
    selectKeeper('  sangsu  ')

    expect(activeKeeperName.value).toBe('sangsu')
    expect(mockInvalidateDashboardCache).toHaveBeenCalledTimes(1)
    expect(mockRefreshDashboard).toHaveBeenCalledTimes(1)
  })

  it('trims the keeper name', () => {
    selectKeeper('\tmulti-line\n ')
    expect(activeKeeperName.value).toBe('multi-line')
  })

  it('allows selection even with empty trimmed name (sets empty string)', () => {
    selectKeeper('   ')
    expect(activeKeeperName.value).toBe('')
    expect(mockInvalidateDashboardCache).toHaveBeenCalledTimes(1)
  })
})

// ─── dispatchKeeperInterjectAction ────────────────────────────────

describe('dispatchKeeperInterjectAction', () => {
  it('returns result for kind "send"', () => {
    const result = dispatchKeeperInterjectAction('send', 'sangsu', 'hello')
    expect(result).toEqual({ action: 'send', name: 'sangsu', prompt: 'hello' })
  })

  it('throws for unknown kind', () => {
    expect(() => dispatchKeeperInterjectAction('other', 'sangsu')).toThrow(
      /unknown interject kind/i,
    )
  })

  it('trims name parameter for send kind', () => {
    const result = dispatchKeeperInterjectAction('send', '  sangsu  ', 'ping')
    expect(result).toEqual({ action: 'send', name: 'sangsu', prompt: 'ping' })
  })
})

// ─── hydrateKeeperStatus ──────────────────────────────────────────

describe('hydrateKeeperStatus', () => {
  it('returns null for empty name', async () => {
    const result = await hydrateKeeperStatus('  ')
    expect(result).toBeNull()
    expect(mockCallMcpTool).not.toHaveBeenCalled()
  })

  it('returns cached status when force=false and entry exists', async () => {
    const existing: KeeperStatusDetail = {
      name: 'sangsu',
      diagnostic: mockDiagnostic(),
      history: [],
      rawText: 'cached',
      rawStatus: null,
      loadedAt: new Date().toISOString(),
    }
    keeperStatusDetails.value = { sangsu: existing }

    const result = await hydrateKeeperStatus('sangsu', false)

    expect(result).toBe(existing) // object identity = no re-fetch
    expect(mockCallMcpTool).not.toHaveBeenCalled()
  })

  it('calls callMcpTool, parses JSON, and normalizes', async () => {
    mockCallMcpTool.mockResolvedValue(mockStatusText())

    const result = await hydrateKeeperStatus('  sangsu  ')

    expect(mockCallMcpTool).toHaveBeenCalledWith('masc_keeper_status', {
      name: 'sangsu',
      fast: true,
      include_context: false,
      include_metrics_overview: false,
      include_memory_bank: false,
      include_history_tail: false,
      include_compaction_history: false,
      tail_turns: 0,
      tail_messages: 0,
    })
    expect(result).not.toBeNull()
    expect(result!.name).toBe('sangsu')
    expect(keeperHydrating.value['sangsu']).toBe(false)
    expect(keeperActionErrors.value['sangsu']).toBeNull()
  })

  it('sets hydration signal true during call and false afterwards', async () => {
    let resolvePromise!: (v: string) => void
    mockCallMcpTool.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))

    const promise = hydrateKeeperStatus('sangsu')
    expect(keeperHydrating.value['sangsu']).toBe(true)

    resolvePromise(mockStatusText())
    await promise

    expect(keeperHydrating.value['sangsu']).toBe(false)
  })

  it('handles JSON parse failure gracefully (returns detail with raw text)', async () => {
    mockCallMcpTool.mockResolvedValue('not valid json')

    const result = await hydrateKeeperStatus('sangsu')

    expect(result).not.toBeNull()
    // normalizeStatusDetail should degrade gracefully with null parsed
    expect(keeperActionErrors.value['sangsu']).toBeNull()
  })

  it('handles MCP tool rejection and sets error', async () => {
    mockCallMcpTool.mockRejectedValue(new Error('MCP timeout'))

    const result = await hydrateKeeperStatus('sangsu')

    expect(result).toBeNull()
    expect(keeperActionErrors.value['sangsu']).toBe('MCP timeout')
    expect(keeperHydrating.value['sangsu']).toBe(false)
  })

  it('forces re-fetch when force=true regardless of cache', async () => {
    const existing: KeeperStatusDetail = {
      name: 'sangsu',
      diagnostic: mockDiagnostic(),
      history: [],
      rawText: 'cached',
      rawStatus: null,
      loadedAt: new Date().toISOString(),
    }
    keeperStatusDetails.value = { sangsu: existing }
    mockCallMcpTool.mockResolvedValue(mockStatusText({ uptime_seconds: 9999 }))

    await hydrateKeeperStatus('sangsu', true)

    expect(mockCallMcpTool).toHaveBeenCalledTimes(1)
  })
})

// ─── loadFullKeeperHistory ────────────────────────────────────────

describe('loadFullKeeperHistory', () => {
  it('returns early for empty name', async () => {
    await loadFullKeeperHistory('  ')
    expect(mockCallMcpTool).not.toHaveBeenCalled()
  })

  it('calls MCP tool with full history params', async () => {
    mockCallMcpTool.mockResolvedValue(mockStatusText({ memory_turns: 99 }))

    await loadFullKeeperHistory('sangsu')

    expect(mockCallMcpTool).toHaveBeenCalledWith('masc_keeper_status', expect.objectContaining({
      name: 'sangsu',
      fast: false,
      include_history_tail: true,
    }))
    expect(keeperHydrating.value['sangsu']).toBe(false)
  })

  it('sets hydration signal true during load and false afterwards', async () => {
    let resolvePromise!: (v: string) => void
    mockCallMcpTool.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))

    const promise = loadFullKeeperHistory('sangsu')
    expect(keeperHydrating.value['sangsu']).toBe(true)

    resolvePromise(mockStatusText())
    await promise

    expect(keeperHydrating.value['sangsu']).toBe(false)
  })

  it('handles MCP tool rejection without throwing', async () => {
    mockCallMcpTool.mockRejectedValue(new Error('history fetch failed'))
    // Should not throw to caller
    await expect(loadFullKeeperHistory('sangsu')).resolves.toBeUndefined()
    expect(keeperHydrating.value['sangsu']).toBe(false)
  })

  it('handles malformed JSON parse gracefully', async () => {
    mockCallMcpTool.mockResolvedValue('{{{ bad json }')

    await expect(loadFullKeeperHistory('sangsu')).resolves.toBeUndefined()
    // parse failure is logged but function should complete
    expect(keeperHydrating.value['sangsu']).toBe(false)
  })
})

// ─── sendKeeperThreadMessage ──────────────────────────────────────

describe('sendKeeperThreadMessage', () => {
  it('returns early for empty name or prompt', async () => {
    await sendKeeperThreadMessage('  ', 'hello')
    await sendKeeperThreadMessage('sangsu', '  ')
    expect(mockStreamKeeperMessage).not.toHaveBeenCalled()
  })

  it('streams message and finalizes entries on success', async () => {
    const onEventFn: { current: ((e: unknown) => void) | null } = { current: null }
    mockStreamKeeperMessage.mockImplementation(
      async (_name: string, _msg: string, opts: { onEvent: (e: unknown) => void }) => {
        onEventFn.current = opts.onEvent
        // Simulate events
        opts.onEvent({ kind: 'text', text: 'Hello back' })
        opts.onEvent({ kind: 'done' })
      },
    )

    await sendKeeperThreadMessage('sangsu', 'hello')

    expect(mockStreamKeeperMessage).toHaveBeenCalledWith('sangsu', 'hello', expect.any(Object))
    // Verify signal states
    expect(keeperSending.value['sangsu']).toBe(false)
    expect(keeperStreamStartedAt.value['sangsu']).toBeNull()
    // Thread entries should be populated
    const entries = keeperThreads.value['sangsu'] ?? []
    expect(entries.length).toBeGreaterThanOrEqual(2)
    // User entry first, assistant entry last
    expect(entries[entries.length - 1].role).toBe('assistant')
  })

  it('falls back to sendKeeperMessageDetailed on stream failure when no partial text', async () => {
    mockStreamKeeperMessage.mockRejectedValue(new Error('stream failed'))
    mockSendKeeperMessageDetailed.mockResolvedValue({
      text: 'fallback reply',
      details: { replyText: 'fallback reply' },
    })

    await sendKeeperThreadMessage('sangsu', 'hello')

    expect(mockSendKeeperMessageDetailed).toHaveBeenCalledWith('sangsu', 'hello')
    expect(keeperSending.value['sangsu']).toBe(false)
  })

  it('throws on stream failure when fallback is not allowed (has partial text)', async () => {
    // Simulate a stream that partially wrote text then failed
    mockStreamKeeperMessage.mockImplementation(
      async (_name: string, _msg: string, opts: { onEvent: (e: unknown) => void }) => {
        opts.onEvent({ kind: 'text', text: 'partial' })
        throw new Error('mid-stream crash')
      },
    )

    await expect(sendKeeperThreadMessage('sangsu', 'hello')).rejects.toThrow('mid-stream crash')
    // Error should be recorded
    expect(keeperActionErrors.value['sangsu']).toContain('mid-stream')
  })

  it('sets sending signal and clears it in finally', async () => {
    let resolvePromise!: () => void
    mockStreamKeeperMessage.mockReturnValue(new Promise(resolve => { resolvePromise = resolve }))
    // Need at least one event or the promise never resolves
    mockStreamKeeperMessage.mockImplementation(
      async (_name: string, _msg: string, opts: { onEvent: (e: unknown) => void }) => {
        opts.onEvent({ kind: 'done' })
      },
    )

    const promise = sendKeeperThreadMessage('sangsu', 'hello')
    expect(keeperSending.value['sangsu']).toBe(true)

    await promise
    expect(keeperSending.value['sangsu']).toBe(false)
  })
})

// ─── probeKeeperRuntime ───────────────────────────────────────────

describe('probeKeeperRuntime', () => {
  it('returns null for empty name', async () => {
    const result = await probeKeeperRuntime('  ', 'executor')
    expect(result).toBeNull()
    expect(mockRunOperatorAction).not.toHaveBeenCalled()
  })

  it('calls runOperatorAction and returns diagnostic', async () => {
    const diagnostic = mockDiagnostic()
    mockRunOperatorAction.mockResolvedValue({
      result: JSON.stringify({ diagnostic }),
    })

    const result = await probeKeeperRuntime('sangsu', 'executor')

    expect(mockRunOperatorAction).toHaveBeenCalledWith({
      actor: 'executor',
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: 'sangsu',
      payload: {},
    })
    expect(result).toEqual(diagnostic)
    expect(keeperProbing.value['sangsu']).toBe(false)
  })

  it('sets probing signal true during call and false after', async () => {
    let resolvePromise!: (v: unknown) => void
    mockRunOperatorAction.mockReturnValue(
      new Promise(resolve => { resolvePromise = resolve }),
    )

    const promise = probeKeeperRuntime('sangsu', 'executor')
    expect(keeperProbing.value['sangsu']).toBe(true)

    resolvePromise({ result: JSON.stringify({ diagnostic: mockDiagnostic() }) })
    await promise

    expect(keeperProbing.value['sangsu']).toBe(false)
  })

  it('throws and sets error on failure', async () => {
    mockRunOperatorAction.mockRejectedValue(new Error('probe timeout'))

    await expect(probeKeeperRuntime('sangsu', 'executor')).rejects.toThrow('probe timeout')
    expect(keeperActionErrors.value['sangsu']).toBe('probe timeout')
    expect(keeperProbing.value['sangsu']).toBe(false)
  })

  it('returns null when normalizeKeeperProbeResult produces no diagnostic', async () => {
    mockRunOperatorAction.mockResolvedValue({ result: '{}' })

    const result = await probeKeeperRuntime('sangsu', 'executor')

    expect(result).toBeNull()
  })

  it('updates keeperStatusDetails when diagnostic is returned', async () => {
    const diagnostic = mockDiagnostic()
    mockRunOperatorAction.mockResolvedValue({
      result: JSON.stringify({ diagnostic }),
    })

    await probeKeeperRuntime('sangsu', 'executor')

    expect(keeperStatusDetails.value['sangsu']).toBeDefined()
    expect(keeperStatusDetails.value['sangsu'].diagnostic).toEqual(diagnostic)
  })
})

// ─── recoverKeeperRuntime ─────────────────────────────────────────

describe('recoverKeeperRuntime', () => {
  it('returns null for empty name', async () => {
    const result = await recoverKeeperRuntime('  ', 'executor')
    expect(result).toBeNull()
    expect(mockRunOperatorAction).not.toHaveBeenCalled()
  })

  it('calls runOperatorAction and returns diagnostic', async () => {
    const diagnostic = mockDiagnostic()
    mockRunOperatorAction.mockResolvedValue({
      result: JSON.stringify({ after: diagnostic }),
    })

    const result = await recoverKeeperRuntime('sangsu', 'executor')

    expect(mockRunOperatorAction).toHaveBeenCalledWith({
      actor: 'executor',
      action_type: 'keeper_recover',
      target_type: 'keeper',
      target_id: 'sangsu',
      payload: {},
    })
    expect(result).toEqual(diagnostic)
    expect(keeperRecovering.value['sangsu']).toBe(false)
  })

  it('sets recovering signal true during call and false after', async () => {
    let resolvePromise!: (v: unknown) => void
    mockRunOperatorAction.mockReturnValue(
      new Promise(resolve => { resolvePromise = resolve }),
    )

    const promise = recoverKeeperRuntime('sangsu', 'executor')
    expect(keeperRecovering.value['sangsu']).toBe(true)

    resolvePromise({ result: JSON.stringify({ after: mockDiagnostic() }) })
    await promise

    expect(keeperRecovering.value['sangsu']).toBe(false)
  })

  it('throws and sets error on failure', async () => {
    mockRunOperatorAction.mockRejectedValue(new Error('recover timeout'))

    await expect(recoverKeeperRuntime('sangsu', 'executor')).rejects.toThrow('recover timeout')
    expect(keeperActionErrors.value['sangsu']).toBe('recover timeout')
    expect(keeperRecovering.value['sangsu']).toBe(false)
  })

  it('returns null when normalizeKeeperRecoverResult produces no after', async () => {
    mockRunOperatorAction.mockResolvedValue({ result: '{}' })

    const result = await recoverKeeperRuntime('sangsu', 'executor')

    expect(result).toBeNull()
  })

  it('updates keeperStatusDetails when after-diagnostic is returned', async () => {
    const diagnostic = mockDiagnostic()
    mockRunOperatorAction.mockResolvedValue({
      result: JSON.stringify({ after: diagnostic }),
    })

    await recoverKeeperRuntime('sangsu', 'executor')

    expect(keeperStatusDetails.value['sangsu']).toBeDefined()
    expect(keeperStatusDetails.value['sangsu'].diagnostic).toEqual(diagnostic)
  })
})
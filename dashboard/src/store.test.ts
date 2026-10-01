import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  agentCoreTotalEvents,
  agentCoreReplayLoadedEvents,
  agentCoreReplayTotalMatchingEvents,
  agentCoreReplayTruncated,
  agentCoreReplayCapped,
  agentCoreTotalLlmCalls,
  agentCoreTotalErrors,
  agentCoreLastLlmCallTs,
  agentCoreLastErrorTs,
  agentCoreEvidenceRefsCount,
  agentCoreArtifactRefsCount,
  agentCoreRawTraceRefsCount,
  agentCoreReportRefsCount,
  agentCoreProofRefsCount,
  agentCoreTelemetryRefsCount,
  agentCoreRuntimeEvidenceRefsCount,
  agentCoreLastEvidenceTs,
  agentCoreHealthSummary,
  noteAgentCoreReplayWindow,
  resetAgentCoreRuntimeSignals,
  pushAgentCoreAgentEvent,
  recordAgentCoreLlmCall,
  recordAgentCoreError,
  recordAgentCoreEvidenceRefs,
} from './store'
import type { AgentCoreAgentEvent } from './types/agent-core'

function resetAgentCoreSignals() {
  resetAgentCoreRuntimeSignals()
}

describe('agentCoreHealthSummary', () => {
  beforeEach(resetAgentCoreSignals)

  it('mirrors raw counter signals', () => {
    agentCoreTotalEvents.value = 10
    agentCoreTotalLlmCalls.value = 4
    agentCoreTotalErrors.value = 2
    expect(agentCoreHealthSummary.value.totalEvents).toBe(10)
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(0)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(0)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(false)
    expect(agentCoreHealthSummary.value.replayCapped).toBe(false)
    expect(agentCoreHealthSummary.value.totalLlmCalls).toBe(4)
    expect(agentCoreHealthSummary.value.totalErrors).toBe(2)
    expect(agentCoreHealthSummary.value.evidenceRefsCount).toBe(0)
  })

  it('tracks replay sample size separately from total matching entries', () => {
    noteAgentCoreReplayWindow({
      loadedEvents: 500,
      totalMatchingEvents: 1842,
      truncated: true,
    })

    expect(agentCoreTotalEvents.value).toBe(1842)
    expect(agentCoreReplayLoadedEvents.value).toBe(500)
    expect(agentCoreReplayTotalMatchingEvents.value).toBe(1842)
    expect(agentCoreReplayTruncated.value).toBe(true)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(1842)
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(500)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(1842)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(true)
    expect(agentCoreHealthSummary.value.replayCapped).toBe(false)
  })

  it('marks a server-capped replay window without offering another page', () => {
    noteAgentCoreReplayWindow({
      loadedEvents: 5499,
      totalMatchingEvents: 6000,
      truncated: false,
      capped: true,
    })

    expect(agentCoreReplayCapped.value).toBe(true)
    expect(agentCoreHealthSummary.value.replayCapped).toBe(true)
    expect(agentCoreHealthSummary.value.hasMore).toBe(false)
  })

  it('reflects agent event buffer length', () => {
    const evt = {
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      phase: 'Running',
    } satisfies AgentCoreAgentEvent
    pushAgentCoreAgentEvent(evt)
    pushAgentCoreAgentEvent({ ...evt, timestamp: 2 })
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(0)
  })

  it('dedups identical consecutive agent events', () => {
    const evt = {
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      event_key: 'same-event',
      phase: 'Running',
    } satisfies AgentCoreAgentEvent
    pushAgentCoreAgentEvent(evt)
    pushAgentCoreAgentEvent(evt)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(1)
  })

  it('keeps distinct events that only share actor and timestamp', () => {
    pushAgentCoreAgentEvent({
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      event_key: 'action',
      phase: 'Paused',
    } satisfies AgentCoreAgentEvent)
    pushAgentCoreAgentEvent({
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      event_key: 'lifecycle',
      phase: 'Running',
      detail: 'started',
    } satisfies AgentCoreAgentEvent)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
  })

  it('starts with zero totals', () => {
    resetAgentCoreSignals()
    const s = agentCoreHealthSummary.value
    expect(s.totalEvents).toBe(0)
    expect(s.replayLoadedEvents).toBe(0)
    expect(s.replayTotalMatchingEvents).toBe(0)
    expect(s.replayTruncated).toBe(false)
    expect(s.replayCapped).toBe(false)
    expect(s.totalLlmCalls).toBe(0)
    expect(s.totalErrors).toBe(0)
    expect(s.agentEventsCount).toBe(0)
    expect(s.lastLlmCallTs).toBeNull()
    expect(s.lastErrorTs).toBeNull()
    expect(s.evidenceRefsCount).toBe(0)
    expect(s.artifactRefsCount).toBe(0)
    expect(s.rawTraceRefsCount).toBe(0)
    expect(s.reportRefsCount).toBe(0)
    expect(s.proofRefsCount).toBe(0)
    expect(s.telemetryRefsCount).toBe(0)
    expect(s.runtimeEvidenceRefsCount).toBe(0)
    expect(s.lastEvidenceTs).toBeNull()
  })
})

describe('recordAgentCoreLlmCall / recordAgentCoreError / recordAgentCoreEvidenceRefs', () => {
  beforeEach(resetAgentCoreSignals)

  it('increments LLM call counter and pins timestamp', () => {
    recordAgentCoreLlmCall(1_700_000_000_000)
    recordAgentCoreLlmCall(1_700_000_060_000)
    expect(agentCoreTotalLlmCalls.value).toBe(2)
    expect(agentCoreLastLlmCallTs.value).toBe(1_700_000_060_000)
    expect(agentCoreHealthSummary.value.lastLlmCallTs).toBe(1_700_000_060_000)
  })

  it('increments error counter and pins timestamp', () => {
    recordAgentCoreError(1_700_000_000_000)
    expect(agentCoreTotalErrors.value).toBe(1)
    expect(agentCoreLastErrorTs.value).toBe(1_700_000_000_000)
    expect(agentCoreHealthSummary.value.lastErrorTs).toBe(1_700_000_000_000)
  })

  it('keeps LLM and error counters independent', () => {
    recordAgentCoreLlmCall(1)
    recordAgentCoreError(2)
    expect(agentCoreTotalLlmCalls.value).toBe(1)
    expect(agentCoreTotalErrors.value).toBe(1)
  })

  it('tracks Agent Core evidence reference counters independently', () => {
    recordAgentCoreEvidenceRefs({
      evidenceRefsCount: 6,
      artifactRefsCount: 2,
      rawTraceRefsCount: 1,
      reportRefsCount: 1,
      proofRefsCount: 1,
      telemetryRefsCount: 1,
      runtimeEvidenceRefsCount: 1,
      tsMs: 1_700_000_000_000,
    })

    expect(agentCoreEvidenceRefsCount.value).toBe(6)
    expect(agentCoreArtifactRefsCount.value).toBe(2)
    expect(agentCoreRawTraceRefsCount.value).toBe(1)
    expect(agentCoreReportRefsCount.value).toBe(1)
    expect(agentCoreProofRefsCount.value).toBe(1)
    expect(agentCoreTelemetryRefsCount.value).toBe(1)
    expect(agentCoreRuntimeEvidenceRefsCount.value).toBe(1)
    expect(agentCoreLastEvidenceTs.value).toBe(1_700_000_000_000)
    expect(agentCoreHealthSummary.value).toMatchObject({
      evidenceRefsCount: 6,
      artifactRefsCount: 2,
      rawTraceRefsCount: 1,
      reportRefsCount: 1,
      proofRefsCount: 1,
      telemetryRefsCount: 1,
      runtimeEvidenceRefsCount: 1,
      lastEvidenceTs: 1_700_000_000_000,
    })
  })
})


describe('manual execution refresh completion through the actual HTTP reader', () => {
  beforeEach(() => { vi.resetModules(); vi.useFakeTimers() })
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); vi.useRealTimers(); vi.resetModules() })

  function execution(generation: number) {
    return {
      generated_at: '2026-09-30T00:00:00Z',
      execution_publication_epoch: 'manual-refresh-fixture',
      execution_publication_generation: generation,
      status: { project: 'same-project', workspace_root: '/fixture/workspace-a' },
      agents: [], tasks: [], messages: [], keepers: [], execution_queue: [],
      worker_support_briefs: [], continuity_briefs: [],
    }
  }
  function json(value: unknown, status = 200) {
    return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } })
  }
  function pendingResponse() {
    let resolve!: (value: Response) => void
    const promise = new Promise<Response>(done => { resolve = done })
    return { promise, resolve }
  }

  it('rejects a delayed pre-purchase overlay within the same execution generation', async () => {
    const store = await import('./store')
    const snapshot = execution(1)
    expect(store.hydrateExecutionSnapshot({ ...snapshot, candle: { status: 'off' }, candle_observation_sequence: 2 })).toBe(true)
    const candle = store.candleObservation.peek()
    const authority = store.executionWorkspaceAuthority.peek()
    expect(store.hydrateExecutionSnapshot({ ...snapshot, candle: { status: 'disabled', reason: 'old failure' }, candle_observation_sequence: 1 })).toBe(false)
    expect(store.candleObservation.peek()).toBe(candle)
    expect(store.executionWorkspaceAuthority.peek()).toBe(authority)
    expect(store.hydrateExecutionSnapshot({ ...snapshot, candle_observation_sequence: 2 })).toBe(true)
    expect(store.hydrateExecutionSnapshot({ ...snapshot, candle_observation_sequence: 3 })).toBe(true)
  })

  it('does not replace a newer same-generation Candle reading with a delayed HTTP failure', async () => {
    const held = pendingResponse()
    const fetch = vi.fn().mockReturnValueOnce(held.promise)
    vi.stubGlobal('fetch', fetch)
    const store = await import('./store')
    store.hydrateExecutionSnapshot({ ...execution(1), candle: { status: 'off' }, candle_observation_sequence: 1 })
    const requested = store.refreshExecution({ force: true })
    const rejected = expect(requested).rejects.toThrow('superseded')
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    store.hydrateExecutionSnapshot({ ...execution(1), candle: { status: 'off' }, candle_observation_sequence: 2 })
    const candle = store.candleObservation.peek()
    held.resolve(json({ error: 'old read failed' }, 503))
    await rejected
    expect(store.candleObservation.peek()).toBe(candle)
    expect(store.executionError.value).toBeNull()
  })

  it('refreshes independent deletion receipts when execution reconciliation fails', async () => {
    const fetch = vi.fn(async (input: string) => {
      if (input.includes('/dashboard/execution')) return json({ error: 'execution unavailable' }, 503)
      if (input.includes('/keepers/deletions')) return json({
        operations: [], errors: [], configuration_removals: [], configuration_errors: [],
      })
      return json({})
    })
    vi.stubGlobal('fetch', fetch)
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const store = await import('./store')
    store.hydrateExecutionSnapshot(execution(0))
    await expect(store.refreshKeeperRuntimeStatus({ force: true })).rejects.toMatchObject({ status: 503 })
    expect(fetch.mock.calls.some(([url]) => url.includes('/keepers/deletions'))).toBe(true)
    expect(store.keeperDeletionInventory.value).toMatchObject({ operations: [], errors: [] })
    expect(store.keeperDeletionError.value).toBeNull()
  })

  it('does not withdraw newer SSE authority for a stale initializing response', async () => {
    const held = pendingResponse()
    const fetch = vi.fn().mockReturnValueOnce(held.promise)
    vi.stubGlobal('fetch', fetch)
    const store = await import('./store')
    store.hydrateExecutionSnapshot(execution(1))
    const requested = store.refreshExecution({ force: true })
    const rejected = expect(requested).rejects.toThrow('superseded')
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    store.hydrateExecutionSnapshot(execution(2))
    const current = store.executionWorkspaceAuthority.peek()
    const candle = store.candleObservation.peek()
    held.resolve(json({ status: { project: 'initializing' } }))
    await rejected
    expect(store.executionWorkspaceAuthority.peek()).toBe(current)
    expect(store.candleObservation.peek()).toBe(candle)
  })

  it('rejects actual HTTP503, keeps the error signals, and permits a new successful refresh', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json({ error: 'Item observation unavailable' }, 503))
      .mockResolvedValueOnce(json(execution(1)))
    vi.stubGlobal('fetch', fetch)
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const store = await import('./store')
    store.hydrateExecutionSnapshot(execution(0))
    const prior = store.executionWorkspaceAuthority.peek()
    expect(prior).not.toBeNull()
    await expect(store.refreshExecution({ force: true })).rejects.toMatchObject({ status: 503 })
    expect(store.executionError.value).not.toBeNull()
    expect(store.candleObservation.value.status).toBe('unavailable')
    expect(store.executionLoading.value).toBe(false)
    expect(store.executionWorkspaceAuthority.peek()).toBeNull()
    await store.refreshExecution({ force: true })
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.executionError.value).toBeNull()
    expect(store.executionWorkspaceAuthority.peek()).not.toBeNull()
    expect(store.executionWorkspaceAuthority.peek()).not.toBe(prior)
    expect(store.executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/fixture/workspace-a')
  })

  it('reconciles the durable purge receipt even when execution HTTP fails', async () => {
    const lifecycle = await import('./api/keeper-lifecycle')
    const hot = await import('./api/dashboard-hot')
    vi.spyOn(hot, 'fetchDashboardShell').mockResolvedValue({ status: {} } as never)
    const receipts = vi.spyOn(lifecycle, 'fetchKeeperDeletions').mockResolvedValue({ operations: [{
      kind: 'runtime_shutdown', source: null, keeperName: 'rondo', operationId: 'purge-1',
      completed: true, canRetry: false, phase: 'finalized', description: 'completed',
    }], errors: [], configurationErrors: [] })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ error: 'projection unavailable' }, 503)))
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const store = await import('./store')
    store.markKeeperPurgePending('rondo')
    await expect(store.refreshKeeperRuntimeStatus({ force: true })).rejects.toMatchObject({ status: 503 })
    expect(receipts).toHaveBeenCalledTimes(1)
    expect(store.keeperPurgePending.value.has('rondo')).toBe(false)
    expect(store.keeperDeletionInventory.value?.operations[0]?.operationId).toBe('purge-1')
  })

  it('keeps forced manual completion pending until its queued HTTP follow-up is accepted', async () => {
    const old = pendingResponse()
    const forced = pendingResponse()
    const fetch = vi.fn().mockReturnValueOnce(old.promise).mockReturnValueOnce(forced.promise)
    vi.stubGlobal('fetch', fetch)
    const store = await import('./store')
    const oldRefresh = store.refreshExecution({ immediate: true })
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    const manual = store.refreshExecution({ force: true })
    const settled = vi.fn()
    void manual.then(settled)
    old.resolve(json(execution(1)))
    await oldRefresh
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
    expect(fetch.mock.calls[1]?.[0]).toBe('/api/v1/dashboard/execution?force=1')
    expect(settled).not.toHaveBeenCalled()
    forced.resolve(json(execution(2)))
    await manual
    expect(settled).toHaveBeenCalledTimes(1)
    expect(store.executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/fixture/workspace-a')
    expect(store.executionError.value).toBeNull()
  })

  it('does not call an initializing envelope a completed refresh while retaining warm retry', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json({ status: 'initializing' }))
      .mockResolvedValueOnce(json(execution(1)))
    vi.stubGlobal('fetch', fetch)
    const store = await import('./store')
    await expect(store.refreshExecution({ force: true })).rejects.toThrow('Execution projection is initializing')
    expect(store.executionWorkspaceAuthority.peek()).toBeNull()
    expect(store.executionLoading.value).toBe(false)
    // Existing warm retry remains scheduled; dispose no new timer policy here.
    expect(vi.getTimerCount()).toBeGreaterThan(0)
    await vi.runOnlyPendingTimersAsync()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/fixture/workspace-a')
  })

  it('rejects a late HTTP failure without withdrawing a newer SSE Candle observation', async () => {
    const held = pendingResponse()
    vi.stubGlobal('fetch', vi.fn().mockReturnValue(held.promise))
    const store = await import('./store')
    store.hydrateExecutionSnapshot(execution(1))
    const requested = store.refreshExecution({ force: true })
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    store.hydrateExecutionSnapshot(execution(2))
    const currentAuthority = store.executionWorkspaceAuthority.peek()
    const currentCandle = store.candleObservation.peek()
    held.resolve(json({ error: 'old request failure' }, 503))
    await expect(requested).rejects.toThrow('Execution failure was superseded by a newer observation')
    expect(store.executionWorkspaceAuthority.peek()).toBe(currentAuthority)
    expect(store.candleObservation.peek()).toBe(currentCandle)
    expect(store.executionError.value).toBeNull()
  })

  it('rejects a superseded held HTTP response without replacing newer accepted authority', async () => {
    const held = pendingResponse()
    vi.stubGlobal('fetch', vi.fn().mockReturnValue(held.promise))
    const store = await import('./store')
    const requested = store.refreshExecution({ force: true })
    store.hydrateExecutionSnapshot(execution(2))
    const current = store.executionWorkspaceAuthority.peek()
    held.resolve(json(execution(1)))
    await expect(requested).rejects.toThrow('Execution response was superseded by a newer observation')
    expect(store.executionWorkspaceAuthority.peek()).toBe(current)
    expect(store.executionError.value).toBeNull()
    expect(store.executionLoading.value).toBe(false)
  })
})

import { beforeEach, describe, expect, it, vi } from 'vitest'
vi.mock('./api/keeper-turn-events', () => ({ fetchKeeperTurnEvents: vi.fn(), fetchKeeperCurrentTurn: vi.fn().mockResolvedValue({ state: 'idle' }) }))
import { fetchKeeperCurrentTurn, fetchKeeperTurnEvents, type KeeperTurnEventPage } from './api/keeper-turn-events'
import { mergeServerHistoryEntries, keeperThreads } from './keeper-state'
import { _resetKeeperStreamBuffersForTests, applyKeeperAutonomousTurnEvent, applyKeeperStreamEvent } from './keeper-stream'
import { _resetKeeperAutonomousRecoveryForTests, discoverKeeperAutonomousTurn, recoverKnownKeeperAutonomousTurns, recoverKeeperAutonomousTurn, recoverKeeperAutonomousHistory } from './keeper-autonomous-stream'
import type { KeeperChatStreamEvent } from './lib/keeper-chat-stream-contract'
const base = { threadId: 'keeper:k', runId: 'trace#9', timestamp: 1 }
const text = (delta: string): KeeperChatStreamEvent => ({ ...base, type: 'TEXT_MESSAGE_CONTENT', messageId: 'trace#9:assistant', textStreamScope: 0, delta })
const page = (sequence: number, event: KeeperChatStreamEvent | null): KeeperTurnEventPage => ({ turnRef: 'trace#9',
  events: [{ sequence, timestamp: 1, event }], cursor: { sequence, offset: sequence + 1 }, hasMore: false })
beforeEach(() => { keeperThreads.value = {}; _resetKeeperStreamBuffersForTests(); _resetKeeperAutonomousRecoveryForTests(); vi.mocked(fetchKeeperTurnEvents).mockReset(); vi.mocked(fetchKeeperCurrentTurn).mockReset().mockResolvedValue({ state: 'idle' }) })
describe('autonomous journal recovery', () => {
  it('discovers a completed autonomous journal from typed history without borrowing direct turns', async () => {
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null,
      traceSteps: [{ kind: 'think', text: '', contentWithheld: true }] },
      { id: 'direct-row', source: 'direct_assistant', role: 'assistant', label: 'k', turnRef: 'other#9',
        text: 'direct answer', delivery: 'history' }])
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce({ turnRef: 'trace#9', hasMore: false,
      cursor: { sequence: 2, offset: 100 }, events: [
        { sequence: 0, timestamp: 1, event: { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
          value: { index: 0, delta: 'exposed reasoning', response: { content_generation: 1, stream_scope: 0 } } } },
        { sequence: 1, timestamp: 1, event: text('journal final body') },
        { sequence: 2, timestamp: 1, event: { ...base, type: 'RUN_FINISHED' } },
      ] })
    await recoverKeeperAutonomousHistory('k')
    expect(fetchKeeperTurnEvents).toHaveBeenCalledWith('k', 'trace#9', { sequence: null, offset: 0 })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')).toMatchObject({
      text: 'canonical answer', delivery: 'history', streamState: null,
      traceSteps: [{ kind: 'think', text: '', contentWithheld: true }, { kind: 'think', text: 'exposed reasoning' }],
      responseState: { phase: 'terminal', lastSequence: 2 },
    })
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce({ turnRef: 'trace#9', hasMore: false,
      cursor: { sequence: 2, offset: 100 }, events: [] })
    await recoverKeeperAutonomousHistory('k')
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')?.traceSteps).toHaveLength(2)
  })
  it('recovers the lost completed tail after a previously observed prefix converges with history', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('live prefix')))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null }])
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce({ turnRef: 'trace#9', hasMore: false,
      cursor: { sequence: 2, offset: 100 }, events: [
        { sequence: 1, timestamp: 1, event: { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
          value: { index: 0, delta: 'exposed completed tail' } } },
        { sequence: 2, timestamp: 1, event: { ...base, type: 'RUN_FINISHED' } },
      ] })
    await recoverKeeperAutonomousHistory('k')
    expect(fetchKeeperTurnEvents).toHaveBeenLastCalledWith('k', 'trace#9', { sequence: 0, offset: 1 })
    expect(keeperThreads.value.k?.[0]).toMatchObject({ text: 'canonical answer', delivery: 'history',
      responseState: { phase: 'terminal', lastSequence: 2 } })
    expect(keeperThreads.value.k?.[0]?.traceSteps).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: 'think', text: 'exposed completed tail' }),
    ]))
  })
  it('retains separate reasoning snapshots across interleaved Keeper pages', async () => {
    try {
      const pending = new Map<string, (page: KeeperTurnEventPage) => void>()
      let bothReading!: () => void
      const ready = new Promise<void>(resolve => { bothReading = resolve })
      const think = (name: string, delta: string): KeeperChatStreamEvent => ({ ...base,
        threadId: `keeper:${name}`, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta, response: { content_generation: 1, stream_scope: 0 } } })
      vi.mocked(fetchKeeperTurnEvents).mockImplementation((name, _turnRef, cursor) => {
        if (cursor?.sequence === null) return Promise.resolve({ ...page(0, think(name, `${name} prefix `)), hasMore: true })
        return new Promise(resolve => {
          pending.set(name, resolve)
          if (pending.size === 2) bothReading()
        })
      })
      const first = recoverKeeperAutonomousTurn('first', 'trace#9', 4)
      const second = recoverKeeperAutonomousTurn('second', 'trace#9', 4)
      await ready
      const parent = (name: string) => keeperThreads.value[name]?.find(entry => entry.source === 'autonomous_turn')
      for (const name of ['first', 'second']) expect(parent(name)?.traceSteps).toMatchObject([
        { kind: 'think', text: `${name} prefix ` },
      ])
      const finish = (name: string): KeeperTurnEventPage => ({ turnRef: 'trace#9', hasMore: false,
        cursor: { sequence: 4, offset: 100 }, events: [
          { sequence: 1, timestamp: 1, event: think(name, 'suffix') },
          { sequence: 2, timestamp: 1, event: { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
            toolCallBlockIndex: 1, toolCallId: 'shared-id', toolCallName: `${name} tool` } },
          { sequence: 3, timestamp: 1, event: text(`${name} answer`) },
          { sequence: 4, timestamp: 1, event: { ...base, type: 'RUN_FINISHED' } },
        ] })
      pending.get('second')!(finish('second'))
      await second
      expect(parent('first')?.traceSteps).toMatchObject([{ kind: 'think', text: 'first prefix ' }])
      expect(parent('first')?.responseState).toMatchObject({ lastSequence: 0 })
      pending.get('first')!(finish('first'))
      await first
      for (const name of ['first', 'second']) expect(parent(name)).toMatchObject({ text: `${name} answer`,
        delivery: 'delivered', streamState: null, responseState: { phase: 'terminal', lastSequence: 4 },
        traceSteps: [{ kind: 'think', text: `${name} prefix suffix` }, { kind: 'tool', name: `${name} tool` }],
      })
      expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(4)
    } finally {
      _resetKeeperStreamBuffersForTests()
    }
  })
  it('isolates actual direct-response reasoning preview timers through tool and Saying commits', () => {
    vi.useFakeTimers()
    try {
      for (const name of ['first', 'second']) keeperThreads.value = { ...keeperThreads.value,
        [name]: [{ id: 'same-entry', role: 'assistant', source: 'direct_assistant', label: name,
          text: '', delivery: 'sending', streamState: 'opening', deliveryProvenance: null }] }
      const parent = (name: string) => keeperThreads.value[name]?.find(entry => entry.id === 'same-entry')
      const send = (name: string, event: KeeperChatStreamEvent) => {
        expect(applyKeeperStreamEvent(name, 'same-entry', { ...event, threadId: `keeper:${name}` })).toBeNull()
      }
      const think = (delta: string): KeeperChatStreamEvent => ({ ...base, type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta,
          response: { content_generation: 1, stream_scope: 0 } } })
      for (const name of ['first', 'second']) send(name, think(`${name} prefix `))
      expect(vi.getTimerCount()).toBeGreaterThan(0)
      vi.runOnlyPendingTimers()
      for (const name of ['first', 'second']) expect(parent(name)?.traceSteps).toMatchObject([
        { kind: 'think', text: `${name} prefix ` },
      ])
      for (const name of ['second', 'first']) {
        send(name, think('suffix'))
        expect(vi.getTimerCount()).toBeGreaterThan(0)
        send(name, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
          toolCallBlockIndex: 1, toolCallId: 'shared-id', toolCallName: `${name} tool` })
        send(name, { ...base, type: 'TEXT_MESSAGE_CONTENT', delta: `${name} answer`,
          textResponse: { content_generation: 1, stream_scope: 0 } })
        expect(parent(name)?.text).toBe(`${name} answer`)
        send(name, { ...base, type: 'RUN_FINISHED' })
      }
      vi.runOnlyPendingTimers()
      for (const name of ['first', 'second']) expect(parent(name)).toMatchObject({
        text: `${name} answer`, responseState: { phase: 'terminal' },
        traceSteps: [{ kind: 'think', text: `${name} prefix suffix` }, { kind: 'tool', name: `${name} tool` }],
      })
    } finally {
      _resetKeeperStreamBuffersForTests()
      vi.useRealTimers()
    }
  })
  it('isolates deferred journal reads and reasoning buffers for Keepers sharing a turn reference', async () => {
    let releaseFirst!: (value: KeeperTurnEventPage) => void
    const journal = (name: string): KeeperTurnEventPage => ({ turnRef: 'trace#9', hasMore: false,
      cursor: { sequence: 3, offset: 100 }, events: [
        { sequence: 0, timestamp: 1, event: { ...base, threadId: `keeper:${name}`, type: 'CUSTOM',
          name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta: `${name} reasoning`,
            response: { content_generation: 1, stream_scope: 0 } } } },
        { sequence: 1, timestamp: 1, event: { ...base, threadId: `keeper:${name}`, type: 'TOOL_CALL_START',
          toolStreamScope: 0, toolCallBlockIndex: 1, toolCallId: 'same-provider-id', toolCallName: `${name} tool` } },
        { sequence: 2, timestamp: 1, event: { ...text(`${name} answer`), threadId: `keeper:${name}` } },
        { sequence: 3, timestamp: 1, event: { ...base, threadId: `keeper:${name}`, type: 'RUN_FINISHED' } },
      ] })
    vi.mocked(fetchKeeperTurnEvents).mockImplementation(name => name === 'first'
      ? new Promise(resolve => { releaseFirst = resolve }) : Promise.resolve(journal(name)))
    const first = recoverKeeperAutonomousTurn('first', 'trace#9', 3)
    await recoverKeeperAutonomousTurn('second', 'trace#9', 3)
    expect(keeperThreads.value.first).toBeUndefined()
    releaseFirst(journal('first'))
    await first
    for (const name of ['first', 'second']) {
      const parent = keeperThreads.value[name]?.find(entry => entry.source === 'autonomous_turn')
      expect(parent).toMatchObject({ text: `${name} answer`, delivery: 'delivered', streamState: null,
        responseState: { phase: 'terminal', lastSequence: 3 }, traceSteps: [
          { kind: 'think', text: `${name} reasoning` }, { kind: 'tool', name: `${name} tool` },
        ] })
      await recoverKeeperAutonomousTurn(name, 'trace#9', 3)
    }
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(2)
  })
  it('renders saying and terminal state without a user message or operation receipt', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('answer'))).mockResolvedValueOnce(page(1, { ...base, type: 'RUN_FINISHED' }))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    await recoverKeeperAutonomousTurn('k', 'trace#9', 1)
    expect(keeperThreads.value.k).toHaveLength(1)
    expect(keeperThreads.value.k?.[0]).toMatchObject({ source: 'autonomous_turn', turnRef: 'trace#9', text: 'answer', delivery: 'delivered', deliveryProvenance: null, streamState: null })
  })
  it('coalesces an interleaved notification and ignores already-applied cursors', async () => {
    let resolve!: (value: KeeperTurnEventPage) => void
    vi.mocked(fetchKeeperTurnEvents).mockReturnValueOnce(new Promise(done => { resolve = done })).mockResolvedValueOnce(page(1, text('b')))
    const first = recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    const second = recoverKeeperAutonomousTurn('k', 'trace#9', 1)
    expect(first).toBe(second)
    resolve(page(0, text('a')))
    await second
    await recoverKeeperAutonomousTurn('k', 'trace#9', 1)
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.k?.[0]?.text).toBe('ab')
  })
  it('retries from the last acknowledged page after a failed read', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockRejectedValueOnce(new Error('read failed')).mockResolvedValueOnce(page(0, text('a')))
    await expect(recoverKeeperAutonomousTurn('k', 'trace#9', 0)).rejects.toThrow('read failed')
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    expect(keeperThreads.value.k?.[0]?.text).toBe('a')
  })
  it('resumes after a later page fails without repeating already-applied speech', async () => {
    vi.mocked(fetchKeeperTurnEvents)
      .mockResolvedValueOnce({ ...page(0, text('first ')), hasMore: true })
      .mockRejectedValueOnce(new Error('second page unavailable'))
      .mockResolvedValueOnce(page(1, text('second')))
    await expect(recoverKeeperAutonomousTurn('k', 'trace#9', 1)).rejects.toThrow('second page unavailable')
    expect(keeperThreads.value.k?.[0]?.text).toBe('first ')
    await recoverKeeperAutonomousTurn('k', 'trace#9', 1)
    expect(fetchKeeperTurnEvents).toHaveBeenLastCalledWith('k', 'trace#9', { sequence: 0, offset: 1 })
    expect(keeperThreads.value.k?.[0]?.text).toBe('first second')
    expect(keeperThreads.value.k?.[0]?.responseState).toMatchObject({ lastSequence: 1 })
  })
  it.each(['notification', 'reconnect'] as const)('honors a pending %s request received while the current read fails', async (request) => {
    let reject!: (error: Error) => void
    vi.mocked(fetchKeeperTurnEvents)
      .mockReturnValueOnce(new Promise((_resolve, fail) => { reject = fail }))
      .mockResolvedValueOnce(page(1, text('recovered')))
    const first = recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    const newer = recoverKeeperAutonomousTurn('k', 'trace#9', request === 'notification' ? 1 : 0, request === 'reconnect')
    expect(newer).toBe(first)
    const failed = expect(first).rejects.toThrow('read failed')
    reject(new Error('read failed'))
    await failed
    await vi.waitFor(() => expect(keeperThreads.value.k?.[0]?.text).toBe('recovered'))
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(2)
  })
  it('does not fabricate content for a connector-only journal row', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, null))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    expect(keeperThreads.value.k).toBeUndefined()
  })
  it('keeps thinking and tool observations on their autonomous parent through history convergence', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'checking', response: { content_generation: 1, stream_scope: 0 } } })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallId: 'provider-tool', toolCallName: 'Read' })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { toolStreamScope: 0, toolCallBlockIndex: 1, toolCallId: 'provider-tool', executionId: 'execution-1' } })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 3, text('answer'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 4, { ...base, type: 'RUN_FINISHED' })
    const parent = keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')
    expect(parent?.traceSteps).toEqual(expect.arrayContaining([expect.objectContaining({ kind: 'think', text: 'checking' }),
      expect.objectContaining({ kind: 'tool', executionId: 'execution-1' })]))
    expect(keeperThreads.value.k?.find(entry => entry.role === 'tool')).toMatchObject({
      executionId: 'execution-1', toolParentEntryId: parent?.id, deliveryProvenance: null })
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'answer', delivery: 'history', timestamp: '1970-01-01T00:00:01.000Z', details: null }])
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')?.responseState).toMatchObject({
      phase: 'terminal', lastSequence: 4 })
  })
  it('recovers thinking after history arrives without rewriting the canonical answer', () => {
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null }])
    for (const [sequence, delta] of ['first ', 'second'].entries()) applyKeeperAutonomousTurnEvent('k', 'trace#9', sequence,
      { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta,
        response: { content_generation: 1, stream_scope: 0 } } })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, text('must not overwrite'))
    expect(keeperThreads.value.k?.[0]).toMatchObject({ text: 'canonical answer', delivery: 'history', streamState: null,
      traceSteps: [{ kind: 'think', text: 'first second' }] })
  })
  it('keeps a live reasoning prefix across history replacement and tool interleaving', () => {
    const think = (sequence: number, delta: string) => applyKeeperAutonomousTurnEvent('k', 'trace#9', sequence,
      { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta,
        response: { content_generation: 1, stream_scope: 0 } } })
    think(0, 'first ')
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical', delivery: 'history', streamState: null, details: null,
      traceSteps: [{ kind: 'tool', name: 'Canonical tool', status: 'ok' }] }])
    think(1, 'second')
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallId: 'provider-tool', toolCallName: 'Read' })
    think(3, 'after tool')
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')?.traceSteps).toMatchObject([
      { kind: 'think', text: 'first second' }, { kind: 'tool' }, { kind: 'think', text: 'after tool' },
    ])
  })
  it('preserves the cursor on exact autonomous history convergence without a trace', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('answer'))
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'answer', delivery: 'history', streamState: null, details: null }])
    expect(keeperThreads.value.k?.[0]?.responseState).toMatchObject({ lastSequence: 0 })
  })
  it('preserves exposed unowned reasoning after an owned response without granting activity authority', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'owned', response: { content_generation: 1, stream_scope: 0 } } })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 1, delta: 'exposed without owner' } })
    expect(keeperThreads.value.k?.[0]?.traceSteps).toEqual(expect.arrayContaining([
      expect.objectContaining({ text: 'owned' }), expect.objectContaining({ text: 'exposed without owner' }),
    ]))
  })
  it.each([true, false])('binds approved tool persistence in either result order (commit first %s)', (commitFirst) => {
    let sequence = 0
    const send = (event: KeeperChatStreamEvent) => applyKeeperAutonomousTurnEvent('k', 'trace#9', sequence++, event)
    const owner = { kind: 'approval_lifecycle' as const, approval_id: 'approval-1' }
    send({ ...base, type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 1,
      toolCallId: 'provider-tool', toolCallName: 'Read' })
    const commit: KeeperChatStreamEvent = { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey: owner, executionId: 'execution-1', ordinal: 0 } }
    const result: KeeperChatStreamEvent = { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { toolStreamScope: 0, toolCallBlockIndex: 1, toolCallId: 'provider-tool', executionId: 'execution-1' } }
    send(commitFirst ? commit : result)
    send(commitFirst ? result : commit)
    const tool = keeperThreads.value.k?.find(entry => entry.role === 'tool')
    expect(tool).toMatchObject({ toolParentEntryId: 'autonomous-trace#9', executionId: 'execution-1', toolTranscriptOrdinal: 0,
      deliveryProvenance: { delivery_key: owner, transcript_slot: { kind: 'tool_call', execution_id: 'execution-1', ordinal: 0 } } })
    mergeServerHistoryEntries('k', [{ id: 'canonical-tool', role: 'tool', source: 'tool_result', label: 'Read', text: 'stored output', delivery: 'history',
      executionId: 'execution-1', deliveryProvenance: tool!.deliveryProvenance }])
    expect(keeperThreads.value.k?.filter(entry => entry.role === 'tool')).toHaveLength(1)
    expect(keeperThreads.value.k?.find(entry => entry.role === 'tool')).toMatchObject({ id: 'canonical-tool', toolParentEntryId: 'autonomous-trace#9' })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')?.traceSteps).toMatchObject([
      { kind: 'tool', toolOccurrenceId: 'canonical-tool', executionId: 'execution-1' },
    ])
    send(commit)
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')?.toolObservationAuthority).not.toBe('unavailable')
  })
  it('converges history arriving between result and acknowledgement', () => {
    const deliveryKey = { kind: 'approval_lifecycle' as const, approval_id: 'approval-1' }
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallName: 'Read', toolCallId: 'provider-tool' })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { toolStreamScope: 0, toolCallBlockIndex: 1, toolCallId: 'provider-tool', executionId: 'execution-1' } })
    mergeServerHistoryEntries('k', [{ id: 'early-canonical', role: 'tool', source: 'tool_result', label: 'Read', text: 'output', delivery: 'history',
      executionId: 'execution-1', deliveryProvenance: { delivery_key: deliveryKey,
        transcript_slot: { kind: 'tool_call', execution_id: 'execution-1', ordinal: 0 } } }])
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'execution-1', ordinal: 0 } })
    expect(keeperThreads.value.k?.filter(entry => entry.role === 'tool')).toHaveLength(1)
    expect(keeperThreads.value.k?.find(entry => entry.role === 'tool')).toMatchObject({ id: 'early-canonical',
      toolParentEntryId: 'autonomous-trace#9', toolOccurrence: { streamScope: 0, blockIndex: 1 } })
  })
  it.each([true, false])('converges canonical history before a result (commit before history %s)', (commitBeforeHistory) => {
    let sequence = 0
    const send = (event: KeeperChatStreamEvent) => applyKeeperAutonomousTurnEvent('k', 'trace#9', sequence++, event)
    const deliveryKey = { kind: 'approval_lifecycle' as const, approval_id: 'approval-1' }
    const commit: KeeperChatStreamEvent = { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'execution-1', ordinal: 0 } }
    send({ ...base, type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 1, toolCallName: 'Read', toolCallId: 'provider-tool' })
    if (commitBeforeHistory) send(commit)
    mergeServerHistoryEntries('k', [{ id: 'canonical-before-result', role: 'tool', source: 'tool_result', label: 'Read', text: 'output', delivery: 'history',
      executionId: 'execution-1', deliveryProvenance: { delivery_key: deliveryKey,
        transcript_slot: { kind: 'tool_call', execution_id: 'execution-1', ordinal: 0 } } }])
    if (!commitBeforeHistory) send(commit)
    send({ ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { toolStreamScope: 0, toolCallBlockIndex: 1, toolCallId: 'provider-tool', executionId: 'execution-1' } })
    expect(keeperThreads.value.k?.filter(entry => entry.role === 'tool')).toHaveLength(1)
    expect(keeperThreads.value.k?.find(entry => entry.role === 'tool')).toMatchObject({ id: 'canonical-before-result', toolParentEntryId: 'autonomous-trace#9' })
  })
  it('retains disputed parent quarantine through canonical history and replay', () => {
    const deliveryKey = { kind: 'approval_lifecycle' as const, approval_id: 'approval-1' }
    for (const turnRef of ['trace#9', 'trace#10']) {
      const send = (sequence: number, event: KeeperChatStreamEvent) => applyKeeperAutonomousTurnEvent('k', turnRef, sequence, event)
      send(0, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 1, toolCallName: 'Read' })
      send(1, { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { toolStreamScope: 0,
        toolCallBlockIndex: 1, executionId: 'execution-1' } })
      send(2, { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED', value: { deliveryKey, executionId: 'execution-1', ordinal: 0 } })
    }
    mergeServerHistoryEntries('k', [{ id: 'disputed-canonical', role: 'tool', source: 'tool_result', label: 'Read', text: 'output', delivery: 'history',
      executionId: 'execution-1', deliveryProvenance: { delivery_key: deliveryKey,
        transcript_slot: { kind: 'tool_call', execution_id: 'execution-1', ordinal: 0 } } }])
    expect(keeperThreads.value.k?.find(entry => entry.id === 'disputed-canonical')).toMatchObject({ toolOccurrenceQuarantined: true,
      toolParentCandidates: ['autonomous-trace#9', 'autonomous-trace#10'] })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 3, { ...base, type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'execution-1', ordinal: 0 } })
    expect(keeperThreads.value.k?.find(entry => entry.id === 'autonomous-trace#9')?.toolObservationAuthority).toBe('unavailable')
    expect(keeperThreads.value.k?.find(entry => entry.id === 'disputed-canonical')?.toolOccurrenceQuarantined).toBe(true)
  })
  it('recovers a terminal event missed during disconnect without another notification', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('answer'))).mockResolvedValueOnce(page(1, { ...base, type: 'RUN_FINISHED' }))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    await recoverKnownKeeperAutonomousTurns()
    expect(keeperThreads.value.k?.[0]).toMatchObject({ text: 'answer', delivery: 'delivered', streamState: null })
    expect(fetchKeeperTurnEvents).toHaveBeenLastCalledWith('k', 'trace#9', { sequence: 0, offset: 1 })
  })
  it('discovers a new current turn for a known Keeper when its first notification was lost', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('previous answer')))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    vi.mocked(fetchKeeperCurrentTurn).mockResolvedValueOnce({ state: 'observed', turnRef: 'trace#10', sequence: 1 })
    vi.mocked(fetchKeeperTurnEvents).mockImplementation((_name, turnRef) => Promise.resolve(turnRef === 'trace#9'
      ? page(1, { ...base, type: 'RUN_FINISHED' })
      : { turnRef: 'trace#10', hasMore: false, cursor: { sequence: 1, offset: 100 }, events: [
        { sequence: 0, timestamp: 2, event: { ...text('new answer'), runId: 'trace#10' } },
        { sequence: 1, timestamp: 2, event: { ...base, runId: 'trace#10', type: 'RUN_FINISHED' } },
      ] }))
    await recoverKnownKeeperAutonomousTurns()
    expect(fetchKeeperCurrentTurn).toHaveBeenCalledWith('k')
    expect(keeperThreads.value.k?.filter(entry => entry.source === 'autonomous_turn')).toMatchObject([
      { turnRef: 'trace#9', text: 'previous answer', delivery: 'delivered' },
      { turnRef: 'trace#10', text: 'new answer', delivery: 'delivered' },
    ])
  })
  it('recovers a known journal while discovery is pending and reports its later failure', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('answer')))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    let rejectDiscovery!: (error: Error) => void
    vi.mocked(fetchKeeperCurrentTurn).mockReturnValueOnce(new Promise((_resolve, reject) => { rejectDiscovery = reject }))
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(1, { ...base, type: 'RUN_FINISHED' }))
    const reconnect = recoverKnownKeeperAutonomousTurns()
    const incomplete = expect(reconnect).rejects.toThrow('Autonomous reconnect journal recovery incomplete')
    await vi.waitFor(() => expect(keeperThreads.value.k?.[0]?.delivery).toBe('delivered'))
    rejectDiscovery(new Error('discovery unavailable'))
    await incomplete
    expect(keeperThreads.value.k?.[0]?.text).toBe('answer')
  })
  it('does not pull the same discovered frontier twice on reconnect', async () => {
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('answer')))
    await recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    vi.mocked(fetchKeeperCurrentTurn).mockResolvedValueOnce({ state: 'observed', turnRef: 'trace#9', sequence: 0 })
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce({ ...page(0, null), events: [] })
    await recoverKnownKeeperAutonomousTurns()
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.k?.[0]?.text).toBe('answer')
  })
  it('queues reconnect recovery behind an in-flight page without parallel reads', async () => {
    let resolve!: (value: KeeperTurnEventPage) => void
    vi.mocked(fetchKeeperTurnEvents).mockReturnValueOnce(new Promise(done => { resolve = done }))
      .mockResolvedValueOnce(page(1, { ...base, type: 'RUN_FINISHED' }))
    const initial = recoverKeeperAutonomousTurn('k', 'trace#9', 0)
    const reconnect = recoverKnownKeeperAutonomousTurns()
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(1)
    resolve(page(0, text('answer')))
    await initial
    await reconnect
    expect(fetchKeeperTurnEvents).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.k?.[0]?.delivery).toBe('delivered')
  })
  it('discovers a running turn on first open using the server identity', async () => {
    vi.mocked(fetchKeeperCurrentTurn).mockResolvedValueOnce({ state: 'observed', turnRef: 'trace#9', sequence: 0 })
    vi.mocked(fetchKeeperTurnEvents).mockResolvedValueOnce(page(0, text('in progress')))
    await discoverKeeperAutonomousTurn('k')
    expect(keeperThreads.value.k?.[0]).toMatchObject({ source: 'autonomous_turn', turnRef: 'trace#9', text: 'in progress' })
    expect(fetchKeeperTurnEvents).toHaveBeenLastCalledWith('k', 'trace#9', { sequence: null, offset: 0 })
  })
  it('does not invent a turn when discovery reports no producer', async () => {
    vi.mocked(fetchKeeperCurrentTurn).mockResolvedValueOnce({ state: 'idle' })
    await discoverKeeperAutonomousTurn('k')
    expect(fetchKeeperTurnEvents).not.toHaveBeenCalled()
    expect(keeperThreads.value.k).toBeUndefined()
  })
  it('recovers historical speech before a tool while keeping the final canonical answer', () => {
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null }])
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('checking '))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, text('files'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallName: 'Read' })
    const parent = keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')
    expect(parent).toMatchObject({ text: 'canonical answer', delivery: 'history', streamState: null,
      traceSteps: [{ kind: 'progress', text: 'checking files' }, { kind: 'tool', name: 'Read' }] })
  })
  it('records saying, thinking and tool transitions in journal order after history', () => {
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null }])
    const think = (sequence: number, delta: string) => applyKeeperAutonomousTurnEvent('k', 'trace#9', sequence,
      { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta,
        response: { content_generation: 1, stream_scope: 0 } } })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('say first'))
    think(1, 'think first')
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, text('say second'))
    think(3, 'think second')
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 4, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallName: 'Read' })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')).toMatchObject({
      text: 'canonical answer', delivery: 'history', streamState: null, traceSteps: [
        { kind: 'progress', text: 'say first' }, { kind: 'think', text: 'think first' },
        { kind: 'progress', text: 'say second' }, { kind: 'think', text: 'think second' }, { kind: 'tool' },
      ],
    })
  })
  it('separates owned speech and retains a live prefix across canonical history', () => {
    const say = (sequence: number, generation: number, delta: string) => applyKeeperAutonomousTurnEvent('k', 'trace#9', sequence,
      { ...base, type: 'TEXT_MESSAGE_CONTENT', delta, textResponse: { content_generation: generation, stream_scope: 0 } })
    say(0, 1, 'live prefix ')
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null }])
    say(1, 1, 'suffix')
    say(2, 2, 'next response')
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 3, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallName: 'Read' })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')).toMatchObject({
      text: 'canonical answer', traceSteps: [ { kind: 'progress', text: 'live prefix suffix' },
        { kind: 'progress', text: 'next response' }, { kind: 'tool' } ],
    })
  })
  it('does not promote final historical speech when a late tool observation arrives', () => {
    mergeServerHistoryEntries('k', [{ id: 'autonomous-trace#9', source: 'autonomous_turn', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', streamState: null, details: null }])
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('canonical answer'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, { ...base, type: 'RUN_FINISHED' })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallName: 'Read' })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')).toMatchObject({
      text: 'canonical answer', traceSteps: [{ kind: 'tool' }], responseState: { phase: 'terminal' },
    })
  })
  it.each(['', undefined])('does not promote live speech on empty or absent reasoning %s', (delta) => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('answer'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, ...(delta === undefined ? {} : { delta }) } })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'RUN_FINISHED' })
    expect(keeperThreads.value.k?.[0]).toMatchObject({ text: 'answer', delivery: 'delivered', streamState: null })
    expect(keeperThreads.value.k?.[0]?.traceSteps ?? []).toEqual([])
  })
  it('does not turn post-terminal text into intermediate speech on a late tool event', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('answer'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1, { ...base, type: 'RUN_FINISHED' })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, text('late duplicate'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 3, { ...base, type: 'TOOL_CALL_START', toolStreamScope: 0,
      toolCallBlockIndex: 1, toolCallName: 'Read' })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')).toMatchObject({ text: 'answer', delivery: 'delivered',
      responseState: { phase: 'terminal', lastSequence: 3 } })
    expect(keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')?.traceSteps?.filter(step => step.kind === 'progress') ?? []).toEqual([])
  })
  it.each(['RUN_FINISHED', 'RUN_ERROR'] as const)('keeps late reasoning outside a %s terminal boundary', (type) => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('answer'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 1,
      type === 'RUN_ERROR' ? { ...base, type, message: 'failed' } : { ...base, type })
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 2, { ...base, type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'late reasoning' } })
    const parent = keeperThreads.value.k?.find(entry => entry.source === 'autonomous_turn')
    expect(parent?.responseState).toMatchObject({ phase: 'terminal', lastSequence: 2 })
    expect(parent?.traceSteps?.filter(step => step.kind === 'think') ?? []).toEqual([])
  })
  it.each([true, false])('does not borrow another producer trace solely from a matching turn reference (autonomous history %s)', (autonomousHistory) => {
    keeperThreads.value = { k: [{ id: 'other-producer', role: 'assistant', source: autonomousHistory ? 'direct_assistant' : 'autonomous_turn', label: 'k',
      turnRef: 'trace#9', text: 'direct answer', delivery: 'delivered', deliveryProvenance: null,
      traceSteps: [{ kind: 'think', text: 'other producer reasoning' }] }] }
    mergeServerHistoryEntries('k', [{ id: 'canonical-producer', source: autonomousHistory ? 'autonomous_turn' : 'direct_assistant', role: 'assistant', label: 'k',
      turnRef: 'trace#9', text: 'canonical answer', delivery: 'history', details: null }])
    expect(keeperThreads.value.k?.find(entry => entry.id === 'canonical-producer')?.traceSteps ?? []).toEqual([])
  })
  it('deduplicates replay at the turn-owned reducer boundary', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('a'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('a'))
    expect(keeperThreads.value.k?.[0]?.text).toBe('a')
  })
})

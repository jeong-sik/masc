import { beforeEach, describe, expect, it, vi } from 'vitest'
vi.mock('./api/keeper-turn-events', () => ({ fetchKeeperTurnEvents: vi.fn(), fetchKeeperCurrentTurn: vi.fn().mockResolvedValue({ state: 'idle' }) }))
import { fetchKeeperCurrentTurn, fetchKeeperTurnEvents, type KeeperTurnEventPage } from './api/keeper-turn-events'
import { mergeServerHistoryEntries, keeperThreads } from './keeper-state'
import { _resetKeeperStreamBuffersForTests, applyKeeperAutonomousTurnEvent } from './keeper-stream'
import { _resetKeeperAutonomousRecoveryForTests, discoverKeeperAutonomousTurn, recoverKnownKeeperAutonomousTurns, recoverKeeperAutonomousTurn } from './keeper-autonomous-stream'
import type { KeeperChatStreamEvent } from './lib/keeper-chat-stream-contract'
const base = { threadId: 'keeper:k', runId: 'trace#9', timestamp: 1 }
const text = (delta: string): KeeperChatStreamEvent => ({ ...base, type: 'TEXT_MESSAGE_CONTENT', messageId: 'trace#9:assistant', textStreamScope: 0, delta })
const page = (sequence: number, event: KeeperChatStreamEvent | null): KeeperTurnEventPage => ({ turnRef: 'trace#9',
  events: [{ sequence, timestamp: 1, event }], cursor: { sequence, offset: sequence + 1 }, hasMore: false })
beforeEach(() => { keeperThreads.value = {}; _resetKeeperStreamBuffersForTests(); _resetKeeperAutonomousRecoveryForTests(); vi.mocked(fetchKeeperTurnEvents).mockReset() })
describe('autonomous journal recovery', () => {
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
  it('deduplicates replay at the turn-owned reducer boundary', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('a'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('a'))
    expect(keeperThreads.value.k?.[0]?.text).toBe('a')
  })
})

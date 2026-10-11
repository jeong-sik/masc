import { beforeEach, describe, expect, it, vi } from 'vitest'
vi.mock('./api/keeper-turn-events', () => ({ fetchKeeperTurnEvents: vi.fn() }))
import { fetchKeeperTurnEvents, type KeeperTurnEventPage } from './api/keeper-turn-events'
import { mergeServerHistoryEntries, keeperThreads } from './keeper-state'
import { _resetKeeperStreamBuffersForTests, applyKeeperAutonomousTurnEvent } from './keeper-stream'
import { _resetKeeperAutonomousRecoveryForTests, recoverKeeperAutonomousTurn } from './keeper-autonomous-stream'
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
  it('deduplicates replay at the turn-owned reducer boundary', () => {
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('a'))
    applyKeeperAutonomousTurnEvent('k', 'trace#9', 0, text('a'))
    expect(keeperThreads.value.k?.[0]?.text).toBe('a')
  })
})

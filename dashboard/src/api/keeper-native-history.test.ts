import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchNativeCalls, fetchNativeEvents } from './keeper-native-history'

const mocks = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('./core', () => mocks)
afterEach(() => vi.clearAllMocks())

const cursor = (scope_id: string, sequence: number) => ({ version: 1, scope_id, sequence })
function eventPage(overrides: Record<string, unknown> = {}) {
  return { schema: 'masc.native_execution_events.v1', operation_id: 'op-a', execution_operation_id: 'batch-a', call_id: 'call-a',
    events: [{ event_id: 'event-1', run_id: 'run-1', correlation_id: 'correlation-1', seq: 1, parent_event_id: null,
      payload: { kind: 'node_opened', node_id: 'node-1', run_id: 'run-1', parent_node_id: null, node: { kind: 'agent_run', agent_name: 'Keeper' } } }],
    next_cursor: cursor('scope-a', 1), high_watermark: cursor('scope-a', 3), has_more: true, ...overrides }
}

describe('native history transport', () => {
  it('forwards the exact Core cursors and rejects a different call or snapshot', async () => {
    mocks.get.mockResolvedValueOnce(eventPage())
    const first = await fetchNativeEvents('keeper-a', 'op-a', 'call-a', null, null)
    expect(mocks.get.mock.calls[0]![1]).toMatchObject({ consumeWithinTimeout: true })
    mocks.get.mockResolvedValueOnce(eventPage({ events: [{ event_id: 'event-2', run_id: 'run-1', correlation_id: 'correlation-1', seq: 2, parent_event_id: 'event-1',
      payload: { kind: 'node_closed', node_id: 'node-1', terminal: { kind: 'succeeded' } } }], next_cursor: cursor('scope-a', 2) }))
    await fetchNativeEvents('keeper-a', 'op-a', 'call-a', first.next_cursor, first.high_watermark)
    const url = new URL(mocks.get.mock.calls[1]![0], 'http://localhost')
    expect(JSON.parse(url.searchParams.get('after')!)).toEqual(first.next_cursor)
    expect(JSON.parse(url.searchParams.get('through')!)).toEqual(first.high_watermark)
    mocks.get.mockResolvedValueOnce(eventPage({ call_id: 'sibling-call' }))
    await expect(fetchNativeEvents('keeper-a', 'op-a', 'call-a', null, null)).rejects.toThrow('다른 호출')
    mocks.get.mockResolvedValueOnce(eventPage({ events: [], high_watermark: cursor('scope-b', 3) }))
    await expect(fetchNativeEvents('keeper-a', 'op-a', 'call-a', first.next_cursor, first.high_watermark)).rejects.toThrow('커서 범위')
  })

  it('does not turn malformed or foreign call pages into an empty successful history', async () => {
    mocks.get.mockResolvedValueOnce({ schema: 'masc.native_execution_calls.v1', operation_id: 'op-a', execution_operation_id: 'batch-a',
      calls: [], next_after_call_id: 'missing-call' })
    await expect(fetchNativeCalls('keeper-a', 'op-a', null)).rejects.toThrow('페이지가 연결')
    expect(mocks.get.mock.calls[0]![1]).toMatchObject({ consumeWithinTimeout: true })
    mocks.get.mockResolvedValueOnce({ schema: 'masc.native_execution_calls.v1', operation_id: 'op-b', execution_operation_id: 'batch-b',
      calls: [], next_after_call_id: null })
    await expect(fetchNativeCalls('keeper-a', 'op-a', null)).rejects.toThrow('다른 요청')
  })
})

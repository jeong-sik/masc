import { h } from 'preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { NativeExecutionHistory } from './native-execution-history'
import type { NativeEventPage } from '../../api/keeper-native-history'

const api = vi.hoisted(() => ({ fetchNativeCalls: vi.fn(), fetchNativeEvents: vi.fn() }))
vi.mock('../../api/keeper-native-history', () => api)
vi.mock('../../api/token-revision', () => ({ storedTokenRevision: { value: 0 } }))

function page(call: string, label: string): NativeEventPage {
  return { execution_operation_id: 'batch', call_id: call,
    events: [{ event_id: `${call}-event`, run_id: `${call}-run`, correlation_id: `${call}-correlation`, seq: 1, parent_event_id: null,
      payload: { kind: 'node_opened', node_id: `${call}-node`, run_id: `${call}-run`, parent_node_id: null, node: { kind: 'agent_run', label } } }],
    next_cursor: { version: 1, scope_id: call, sequence: 1 }, high_watermark: { version: 1, scope_id: call, sequence: 1 }, has_more: false }
}

beforeEach(() => {
  api.fetchNativeCalls.mockImplementation(async (keeper: string) => ({ execution_operation_id: 'batch',
    calls: [{ call_id: keeper, runtime_id: 'native', trace_id: 'original-trace' }], next_after_call_id: null }))
})
afterEach(() => { cleanup(); vi.resetAllMocks() })

describe('completed execution observation', () => {
  it('aborts and discards the prior Keeper response after the observed operation changes', async () => {
    let finishOld: ((page: NativeEventPage) => void) | undefined
    api.fetchNativeEvents.mockImplementation((keeper: string) => keeper === 'a'
      ? new Promise<NativeEventPage>(resolve => { finishOld = resolve })
      : Promise.resolve(page('b', 'Current Keeper')))
    const view = render(h(NativeExecutionHistory, { keeper: 'a', operation: 'op-a', turnComplete: true }))
    fireEvent.click(view.getByRole('button', { name: 'Core 실행 이력' }))
    await waitFor(() => expect(api.fetchNativeEvents).toHaveBeenCalledTimes(1))
    const oldSignal = api.fetchNativeEvents.mock.calls[0]![5] as AbortSignal
    view.rerender(h(NativeExecutionHistory, { keeper: 'b', operation: 'op-b', turnComplete: true }))
    expect(oldSignal.aborted).toBe(true)
    fireEvent.click(view.getByRole('button', { name: 'Core 실행 이력' }))
    await view.findByText('Current Keeper')
    finishOld!(page('a', 'Previous Keeper'))
    await waitFor(() => expect(view.queryByText('Previous Keeper')).toBeNull())
    expect(api.fetchNativeEvents.mock.calls[1]!.slice(0, 3)).toEqual(['b', 'op-b', 'b'])
  })

  it('keeps an unavailable Core journal as an error without synthesizing a trajectory', async () => {
    api.fetchNativeEvents.mockRejectedValue(new Error('journal missing'))
    const view = render(h(NativeExecutionHistory, { keeper: 'a', operation: 'op-a', turnComplete: true }))
    fireEvent.click(view.getByRole('button', { name: 'Core 실행 이력' }))
    expect((await view.findByRole('alert')).textContent).toContain('journal missing')
    expect(view.container.querySelectorAll('[data-native-node]').length).toBe(0)
    expect(api.fetchNativeEvents).toHaveBeenCalledTimes(1)
  })
})

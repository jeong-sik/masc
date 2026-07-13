// Stale-while-revalidate guard for the Gate resource.
//
// gateResource backs the Gate/HITL surface. It must NOT blank its data
// while a refresh is in flight:
// refreshGate() runs on mount, on every auto-refresh tick, and after every
// approve/reject. If a refetch cleared the data, the approvals queue would flash
// its "열린 승인이 없습니다" empty state every cycle. This pins that the previous
// data stays visible (loading=true, data=previous) until the new data arrives.

import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DashboardGateResponse, KeeperApprovalQueueItem } from '../types'

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(r => {
    resolve = r
  })
  return { promise, resolve }
}

function queueItem(id: string): KeeperApprovalQueueItem {
  return {
    id,
    keeper_name: 'keeper-x',
    tool_name: 'fs_write',
    waiting_s: 10,
    input_preview: 'x',
    task_id: 'T-1',
  } as KeeperApprovalQueueItem
}

function response(queue: KeeperApprovalQueueItem[]): DashboardGateResponse {
  return {
    generated_at: '2026-06-24T00:00:00Z',
    approval_queue: queue,
    recent_resolved: [],
    approval_rules: [],
  } as DashboardGateResponse
}

async function loadGate() {
  vi.resetModules()
  const fetchDashboardGate = vi.fn()
  vi.doMock('../api', () => ({
    fetchDashboardGate,
    resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
    deleteGateApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
    setGateMode: vi.fn().mockResolvedValue({ ok: true }),
  }))
  vi.doMock('../api/dashboard-gate', () => ({
    fetchDashboardGate,
    resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
    deleteGateApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
    setGateMode: vi.fn().mockResolvedValue({ ok: true }),
  }))
  vi.doMock('../sse-store', () => ({ registerGateRefresh: vi.fn() }))
  const signals = await import('./gate-signals')
  const actions = await import('./gate-actions')
  return { fetchDashboardGate, signals, actions }
}

afterEach(() => {
  vi.resetModules()
  vi.clearAllMocks()
  vi.doUnmock('../api')
  vi.doUnmock('../api/dashboard-gate')
  vi.doUnmock('../sse-store')
})

describe('Gate resource (stale-while-revalidate)', () => {
  it('keeps the previously loaded data visible while a refresh is in flight', async () => {
    const { fetchDashboardGate, signals, actions } = await loadGate()

    fetchDashboardGate.mockResolvedValueOnce(response([queueItem('a1')]))
    await actions.refreshGate()
    expect(signals.gateData.value?.approval_queue).toHaveLength(1)
    expect(signals.gateLoading.value).toBe(false)

    // Second refresh is in flight (its fetch has not resolved yet).
    const pending = deferred<DashboardGateResponse>()
    fetchDashboardGate.mockReturnValueOnce(pending.promise)
    const inflight = actions.refreshGate()
    await Promise.resolve()

    // Loading is true, but the previous queue is STILL visible — not blanked.
    expect(signals.gateLoading.value).toBe(true)
    expect(signals.gateData.value?.approval_queue).toHaveLength(1)

    // Once the refresh resolves, the new data replaces it.
    pending.resolve(response([]))
    await inflight
    expect(signals.gateLoading.value).toBe(false)
    expect(signals.gateData.value?.approval_queue).toHaveLength(0)
  })

  it('retains the last good data and surfaces the message when a refresh fails', async () => {
    const { fetchDashboardGate, signals, actions } = await loadGate()

    fetchDashboardGate.mockResolvedValueOnce(response([queueItem('a1')]))
    await actions.refreshGate()

    fetchDashboardGate.mockRejectedValueOnce(new Error('Gate 새로고침 실패'))
    await actions.refreshGate()

    // Failure does not wipe the queue, and the error is visible (no silent failure).
    expect(signals.gateData.value?.approval_queue).toHaveLength(1)
    expect(signals.gateError.value).toContain('Gate 새로고침 실패')
    expect(signals.gateLoading.value).toBe(false)
  })
})

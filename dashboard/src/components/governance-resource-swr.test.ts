// Stale-while-revalidate guard for the governance resource.
//
// governanceResource backs both the governance command surface and the HITL
// approvals surface. It must NOT blank its data while a refresh is in flight:
// refreshGovernance() runs on mount, on every auto-refresh tick, and after every
// approve/reject. If a refetch cleared the data, the approvals queue would flash
// its "열린 승인이 없습니다" empty state every cycle. This pins that the previous
// data stays visible (loading=true, data=previous) until the new data arrives.

import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DashboardGovernanceResponse, KeeperApprovalQueueItem } from '../types'

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
    risk_level: 'critical',
    waiting_s: 10,
    input_preview: 'x',
    task_id: 'T-1',
  } as KeeperApprovalQueueItem
}

function response(queue: KeeperApprovalQueueItem[]): DashboardGovernanceResponse {
  return {
    generated_at: '2026-06-24T00:00:00Z',
    summary: { judge_online: false },
    items: [],
    activity: [],
    judgments: [],
    pending_actions: [],
    approval_queue: queue,
  } as DashboardGovernanceResponse
}

async function loadGovernance() {
  vi.resetModules()
  const fetchDashboardGovernance = vi.fn()
  vi.doMock('../api', () => ({
    fetchDashboardGovernance,
    fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
    decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
    resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true }),
    deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
    submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
    submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
  }))
  vi.doMock('../api/dashboard-governance', () => ({
    fetchDashboardGovernance,
    fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
    decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
    resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true }),
    deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
    submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
    submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
  }))
  vi.doMock('../sse-store', () => ({ registerGovernanceRefresh: vi.fn() }))
  const signals = await import('./governance-signals')
  const actions = await import('./governance-actions')
  return { fetchDashboardGovernance, signals, actions }
}

afterEach(() => {
  vi.resetModules()
  vi.clearAllMocks()
  vi.doUnmock('../api')
  vi.doUnmock('../api/dashboard-governance')
  vi.doUnmock('../sse-store')
})

describe('governance resource (stale-while-revalidate)', () => {
  it('keeps the previously loaded data visible while a refresh is in flight', async () => {
    const { fetchDashboardGovernance, signals, actions } = await loadGovernance()

    fetchDashboardGovernance.mockResolvedValueOnce(response([queueItem('a1')]))
    await actions.refreshGovernance()
    expect(signals.governanceData.value?.approval_queue).toHaveLength(1)
    expect(signals.governanceLoading.value).toBe(false)

    // Second refresh is in flight (its fetch has not resolved yet).
    const pending = deferred<DashboardGovernanceResponse>()
    fetchDashboardGovernance.mockReturnValueOnce(pending.promise)
    const inflight = actions.refreshGovernance()
    await Promise.resolve()

    // Loading is true, but the previous queue is STILL visible — not blanked.
    expect(signals.governanceLoading.value).toBe(true)
    expect(signals.governanceData.value?.approval_queue).toHaveLength(1)

    // Once the refresh resolves, the new data replaces it.
    pending.resolve(response([]))
    await inflight
    expect(signals.governanceLoading.value).toBe(false)
    expect(signals.governanceData.value?.approval_queue).toHaveLength(0)
  })

  it('retains the last good data and surfaces the message when a refresh fails', async () => {
    const { fetchDashboardGovernance, signals, actions } = await loadGovernance()

    fetchDashboardGovernance.mockResolvedValueOnce(response([queueItem('a1')]))
    await actions.refreshGovernance()

    fetchDashboardGovernance.mockRejectedValueOnce(new Error('거버넌스 새로고침 실패'))
    await actions.refreshGovernance()

    // Failure does not wipe the queue, and the error is visible (no silent failure).
    expect(signals.governanceData.value?.approval_queue).toHaveLength(1)
    expect(signals.governanceError.value).toContain('거버넌스 새로고침 실패')
    expect(signals.governanceLoading.value).toBe(false)
  })
})

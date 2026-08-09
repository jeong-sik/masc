import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  refreshGate: vi.fn(),
  setGateMode: vi.fn(),
  retryGateAutoJudge: vi.fn(),
  resolveGateApproval: vi.fn(),
  deleteGateApprovalRule: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('./common/toast', () => ({
  showToast: mocks.showToast,
}))

vi.mock('../api/dashboard-gate', () => ({
  deleteGateApprovalRule: mocks.deleteGateApprovalRule,
  resolveGateApproval: mocks.resolveGateApproval,
  retryGateAutoJudge: mocks.retryGateAutoJudge,
  setGateMode: mocks.setGateMode,
}))

vi.mock('./gate-refresh', () => ({
  refreshGate: mocks.refreshGate,
}))

import {
  deleteKeeperApprovalRule,
  respondToKeeperApproval,
  retryKeeperAutoJudge,
  setKeeperGateMode,
} from './gate-actions'
import {
  clearGateAuditWriteFailures,
  gateApprovalActing,
  gateAuditWriteFailures,
  gateError,
  observeGateAuditReceipts,
} from './gate-signals'

const baseResponse = {
  ok: true,
  mode: 'auto_judge',
  previous_mode: 'manual',
  actor: 'operator',
  changed_at: '2026-07-16T00:00:00Z',
  recovery_error: null,
  started: 0,
  queued: 0,
  recovery_failure_count: 0,
  recovery_failures: [],
} as const

beforeEach(() => {
  mocks.refreshGate.mockReset().mockResolvedValue(undefined)
  mocks.setGateMode.mockReset()
  mocks.retryGateAutoJudge.mockReset().mockResolvedValue({ ok: true, id: 'appr-1' })
  mocks.resolveGateApproval.mockReset()
  mocks.deleteGateApprovalRule.mockReset()
  mocks.showToast.mockReset()
  clearGateAuditWriteFailures()
  gateApprovalActing.value = null
  gateError.value = ''
})

describe('committed Gate mutation audit degradation', () => {
  it('keeps resolution successful and publishes the failed audit receipt', async () => {
    mocks.resolveGateApproval.mockResolvedValue({
      ok: true,
      id: 'appr-audit',
      decision: 'approve',
      rule_id: null,
      audit_receipts: [{
        event: 'resolved',
        recorded: false,
        stage: 'append',
        detail: 'audit append unavailable',
      }],
    })

    await respondToKeeperApproval('appr-audit', 'approve')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'keeper 승인 요청을 승인했습니다 · 감사 기록은 저장되지 않았습니다',
      'warning',
    )
    expect(gateAuditWriteFailures.value).toMatchObject([{
      id: 'appr-audit',
      transport: 'http',
      receipt: { event: 'resolved', recorded: false, stage: 'append' },
    }])
  })

  it('keeps rule deletion successful and publishes the failed audit receipt', async () => {
    mocks.deleteGateApprovalRule.mockResolvedValue({
      ok: true,
      id: 'rule-audit',
      audit: {
        event: 'rule_deleted',
        recorded: false,
        stage: 'store_create',
        detail: 'audit store unavailable',
      },
    })

    await deleteKeeperApprovalRule('rule-audit')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Always 규칙을 삭제했습니다 · 감사 기록은 저장되지 않았습니다',
      'warning',
    )
    expect(gateAuditWriteFailures.value[0]).toMatchObject({
      id: 'rule-audit',
      receipt: { event: 'rule_deleted', stage: 'store_create' },
    })
  })

  it('does not collapse distinct uncorrelated authorization failures', () => {
    const receipt = {
      event: 'gate_allowed' as const,
      recorded: false as const,
      stage: 'append' as const,
      detail: 'approval audit write failed',
    }
    observeGateAuditReceipts([receipt], { id: null, transport: 'sse' })
    observeGateAuditReceipts([receipt], { id: null, transport: 'sse' })

    expect(gateAuditWriteFailures.value).toHaveLength(2)
  })
})

describe('retryKeeperAutoJudge exact observation', () => {
  it('forwards the complete observed row identity', async () => {
    const expected = {
      input_hash: 'a'.repeat(64),
      sequence: 7,
      exact_attempt: { state: 'unbound' as const },
      summary_attempt_disposition: {
        code: 'identity_unbound' as const,
        operator_detail:
          'Exact-output terminalization stopped before an attempt identity was bound.',
      },
    }

    await retryKeeperAutoJudge('appr-1', expected)

    expect(mocks.retryGateAutoJudge).toHaveBeenCalledWith('appr-1', expected)
  })
})

describe('setKeeperGateMode recovery result', () => {
  it('keeps the saved mode successful, warns on failed recovery, and refreshes', async () => {
    mocks.setGateMode.mockResolvedValue({
      ...baseResponse,
      recovery_status: 'failed',
      recovery_error: 'judge worker unavailable',
    })

    await setKeeperGateMode('auto_judge')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Gate 모드를 Auto Judge(으)로 저장했습니다 · Auto Judge backlog recovery 실패: judge worker unavailable',
      'warning',
    )
    expect(mocks.refreshGate).toHaveBeenCalledWith({ force: true })
    expect(gateError.value).toBe('')
    expect(gateApprovalActing.value).toBeNull()
  })

  it('reports completed recovery with every observed count and refreshes', async () => {
    mocks.setGateMode.mockResolvedValue({
      ...baseResponse,
      recovery_status: 'completed',
      started: 1,
      queued: 1,
    })

    await setKeeperGateMode('auto_judge')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Gate 모드를 Auto Judge(으)로 저장했습니다 · Auto Judge backlog recovery 요청 처리 완료'
      + ' (started 1, queued 1)',
      'success',
    )
    expect(mocks.refreshGate).toHaveBeenCalledWith({ force: true })
  })

  it('reports partial recovery without hiding a healthy owner start', async () => {
    mocks.setGateMode.mockResolvedValue({
      ...baseResponse,
      recovery_status: 'partial',
      started: 1,
      queued: 2,
      recovery_failure_count: 1,
      recovery_failures: [{
        keeper_name: 'keeper-a',
        approval_id: null,
        operator_detail: 'queue unavailable',
      }],
    })

    await setKeeperGateMode('auto_judge')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Gate 모드를 Auto Judge(으)로 저장했습니다 · Auto Judge backlog recovery 부분 완료'
      + ' (started 1, queued 2, failed 1) · keeper-a: queue unavailable',
      'warning',
    )
    expect(mocks.refreshGate).toHaveBeenCalledWith({ force: true })
  })

  it('reports that recovery was not requested and refreshes', async () => {
    mocks.setGateMode.mockResolvedValue({
      ...baseResponse,
      mode: 'manual',
      recovery_status: 'not_requested',
    })

    await setKeeperGateMode('manual')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Gate 모드를 Human(으)로 저장했습니다 · backlog recovery 비적용',
      'success',
    )
    expect(mocks.refreshGate).toHaveBeenCalledWith({ force: true })
  })
})

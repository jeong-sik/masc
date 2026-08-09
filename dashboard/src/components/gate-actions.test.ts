import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  refreshGate: vi.fn(),
  resolveGateApproval: vi.fn(),
  setGateMode: vi.fn(),
  retryGateAutoJudge: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('./common/toast', () => ({
  showToast: mocks.showToast,
}))

vi.mock('../api/dashboard-gate', () => ({
  deleteGateApprovalRule: vi.fn(),
  resolveGateApproval: mocks.resolveGateApproval,
  retryGateAutoJudge: mocks.retryGateAutoJudge,
  setGateMode: mocks.setGateMode,
}))

vi.mock('./gate-refresh', () => ({
  refreshGate: mocks.refreshGate,
}))

import {
  respondToKeeperApproval,
  retryKeeperAutoJudge,
  setKeeperGateMode,
} from './gate-actions'
import { gateApprovalActing, gateError } from './gate-signals'

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
  Object.defineProperty(window, 'prompt', {
    value: vi.fn().mockReturnValue('operator rejected'),
    configurable: true,
    writable: true,
  })
  mocks.refreshGate.mockReset().mockResolvedValue(undefined)
  mocks.resolveGateApproval.mockReset().mockResolvedValue({
    ok: true,
    id: 'appr-1',
    decision: 'approve',
    rule_id: null,
    rule_error: null,
  })
  mocks.setGateMode.mockReset()
  mocks.retryGateAutoJudge.mockReset().mockResolvedValue({ ok: true, id: 'appr-1' })
  mocks.showToast.mockReset()
  gateApprovalActing.value = null
  gateError.value = ''
})

describe('respondToKeeperApproval rejection reason', () => {
  it('sends the operator-entered reason unchanged', async () => {
    const prompt = vi.spyOn(window, 'prompt').mockReturnValueOnce('  범위 밖 작업  ')

    await respondToKeeperApproval('appr-1', 'reject')

    expect(mocks.resolveGateApproval).toHaveBeenCalledWith(
      'appr-1',
      { decision: 'reject', reason: '  범위 밖 작업  ' },
    )
    expect(mocks.refreshGate).toHaveBeenCalledWith({ force: true })
    prompt.mockRestore()
  })

  it('does not resolve without an operator-entered reason', async () => {
    const prompt = vi.spyOn(window, 'prompt').mockReturnValueOnce('   ')

    await respondToKeeperApproval('appr-1', 'reject')

    expect(mocks.resolveGateApproval).not.toHaveBeenCalled()
    expect(mocks.showToast).toHaveBeenCalledWith('거부 이유를 입력해야 합니다', 'warning')
    prompt.mockRestore()
  })

  it('shows committed approval and failed rule persistence separately', async () => {
    mocks.resolveGateApproval.mockResolvedValueOnce({
      ok: true,
      id: 'appr-1',
      decision: 'approve',
      rule_id: null,
      rule_error: 'approval-rules.json: exact rule has a different expiry',
    })

    await respondToKeeperApproval('appr-1', 'approve', true)

    expect(mocks.showToast).toHaveBeenCalledWith(
      'keeper 승인 요청은 승인했지만 Always 규칙을 저장하지 못했습니다: '
      + 'approval-rules.json: exact rule has a different expiry',
      'warning',
    )
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

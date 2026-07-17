import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  refreshGate: vi.fn(),
  setGateMode: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('./common/toast', () => ({
  showToast: mocks.showToast,
}))

vi.mock('../api/dashboard-gate', () => ({
  deleteGateApprovalRule: vi.fn(),
  resolveGateApproval: vi.fn(),
  retryGateAutoJudge: vi.fn(),
  setGateMode: mocks.setGateMode,
}))

vi.mock('./gate-refresh', () => ({
  refreshGate: mocks.refreshGate,
}))

import { setKeeperGateMode } from './gate-actions'
import { gateApprovalActing, gateError } from './gate-signals'

const baseResponse = {
  ok: true,
  mode: 'auto_judge',
  previous_mode: 'manual',
  actor: 'operator',
  changed_at: '2026-07-16T00:00:00Z',
  recovery_error: null,
  reopened: 0,
  started: 0,
  queued: 0,
} as const

beforeEach(() => {
  mocks.refreshGate.mockReset().mockResolvedValue(undefined)
  mocks.setGateMode.mockReset()
  mocks.showToast.mockReset()
  gateApprovalActing.value = null
  gateError.value = ''
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
      reopened: 2,
      started: 1,
      queued: 1,
    })

    await setKeeperGateMode('auto_judge')

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Gate 모드를 Auto Judge(으)로 저장했습니다 · Auto Judge backlog recovery 요청 처리 완료'
      + ' (reopened 2, started 1, queued 1)',
      'success',
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

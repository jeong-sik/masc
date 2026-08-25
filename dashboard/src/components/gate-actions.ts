import { showToast } from './common/toast'
import {
  deleteGateApprovalRule,
  resolveGateApproval,
  retryGateAutoJudge,
  setGateMode,
} from '../api/dashboard-gate'
import type { SetGateModeResponse } from '../api/dashboard-gate'
import type { GateMode, KeeperAutoJudgeRearmExpectation } from '../types'
import { refreshGate } from './gate-refresh'
import {
  gateApprovalActing,
  gateError,
  observeGateAuditReceipts,
} from './gate-signals'
export { refreshGate }

export async function respondToKeeperApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule = false,
) {
  if (!id) return
  const resolution = (() => {
    if (decision === 'approve') return { decision, rememberRule } as const
    const reason = window.prompt('승인 요청을 거부하는 이유를 입력하세요.')
    if (reason === null || reason.trim() === '') return null
    return { decision, reason } as const
  })()
  if (resolution === null) {
    showToast('거부 이유를 입력해야 합니다', 'warning')
    return
  }
  gateApprovalActing.value = id
  try {
    const result = await resolveGateApproval(id, resolution)
    observeGateAuditReceipts(result.audit_receipts, { id, transport: 'http' })
    const auditFailed = result.audit_receipts.some(receipt => !receipt.recorded)
    const message = decision === 'approve'
      ? (rememberRule ? 'keeper 승인 요청을 승인하고 Always 규칙을 저장했습니다' : 'keeper 승인 요청을 승인했습니다')
      : 'keeper 승인 요청을 거부했습니다'
    showToast(
      auditFailed ? `${message} · 감사 기록은 저장되지 않았습니다` : message,
      auditFailed ? 'warning' : 'success',
    )
    await refreshGate({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'keeper 승인 요청을 처리하지 못했습니다'
    gateError.value = message
    showToast(message, 'error')
  } finally {
    gateApprovalActing.value = null
  }
}

export async function retryKeeperAutoJudge(
  id: string,
  expected: KeeperAutoJudgeRearmExpectation,
) {
  if (!id) return
  gateApprovalActing.value = id
  try {
    await retryGateAutoJudge(id, expected)
    showToast('Auto Judge를 한 번 다시 요청했습니다', 'success')
    await refreshGate({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Auto Judge를 다시 요청하지 못했습니다'
    gateError.value = message
    showToast(message, 'error')
  } finally {
    gateApprovalActing.value = null
  }
}

export async function deleteKeeperApprovalRule(id: string) {
  if (!id) return
  gateApprovalActing.value = `rule:${id}`
  try {
    const result = await deleteGateApprovalRule(id)
    observeGateAuditReceipts([result.audit], { id, transport: 'http' })
    const auditFailed = !result.audit.recorded
    showToast(
      auditFailed
        ? 'Always 규칙을 삭제했습니다 · 감사 기록은 저장되지 않았습니다'
        : 'Always 규칙을 삭제했습니다',
      auditFailed ? 'warning' : 'success',
    )
    await refreshGate({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Always 규칙을 삭제하지 못했습니다'
    gateError.value = message
    showToast(message, 'error')
  } finally {
    gateApprovalActing.value = null
  }
}

export const GATE_MODE_ACTING_KEY = 'gate-mode'

function gateModeLabel(mode: GateMode): string {
  return mode === 'manual' ? 'Human' : mode === 'auto_judge' ? 'Auto Judge' : 'Always Allow'
}

function showGateModeSaved(result: SetGateModeResponse): void {
  const saved = `Gate 모드를 ${gateModeLabel(result.mode)}(으)로 저장했습니다`
  switch (result.recovery_status) {
    case 'completed':
      showToast(
        `${saved} · Auto Judge backlog recovery 요청 처리 완료`
        + ` (started ${result.started.toLocaleString()},`
        + ` queued ${result.queued.toLocaleString()})`,
        'success',
      )
      return
    case 'partial': {
      const firstFailure = result.recovery_failures[0]
      const firstFailureDetail = firstFailure
        ? ` · ${firstFailure.keeper_name}: ${firstFailure.operator_detail}`
        : ''
      showToast(
        `${saved} · Auto Judge backlog recovery 부분 완료`
        + ` (started ${result.started.toLocaleString()},`
        + ` queued ${result.queued.toLocaleString()},`
        + ` failed ${result.recovery_failure_count.toLocaleString()})`
        + firstFailureDetail,
        'warning',
      )
      return
    }
    case 'failed':
      showToast(
        `${saved} · Auto Judge backlog recovery 실패:`
        + ` ${result.recovery_error ?? '상세 오류 없음'}`,
        'warning',
      )
      return
    case 'not_requested':
      showToast(`${saved} · backlog recovery 비적용`, 'success')
      return
    default: {
      const unreachable: never = result.recovery_status
      throw new Error(`unsupported Gate recovery status: ${String(unreachable)}`)
    }
  }
}

export async function setKeeperGateMode(mode: GateMode) {
  gateApprovalActing.value = GATE_MODE_ACTING_KEY
  try {
    let result: SetGateModeResponse
    try {
      result = await setGateMode(mode)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Gate 모드를 저장하지 못했습니다'
      gateError.value = message
      showToast(message, 'error')
      return
    }

    showGateModeSaved(result)
    try {
      await refreshGate({ force: true })
    } catch (err) {
      const detail = err instanceof Error ? err.message : '상세 오류 없음'
      const message = `Gate 모드는 저장됐지만 새로고침하지 못했습니다: ${detail}`
      gateError.value = message
      showToast(message, 'warning')
    }
  } finally {
    gateApprovalActing.value = null
  }
}

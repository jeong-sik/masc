import { showToast } from './common/toast'
import {
  deleteGateApprovalRule,
  resolveGateApproval,
  setGateMode,
} from '../api/dashboard-gate'
import type { GateMode } from '../types'
import { refreshGate } from './gate-refresh'
import {
  gateApprovalActing,
  gateError,
} from './gate-signals'
export { refreshGate }

export async function respondToKeeperApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule = false,
) {
  if (!id) return
  gateApprovalActing.value = id
  try {
    await resolveGateApproval(id, decision, rememberRule)
    const message =
      decision === 'approve'
        ? (rememberRule ? 'keeper 승인 요청을 승인하고 Always 규칙을 저장했습니다' : 'keeper 승인 요청을 승인했습니다')
        : 'keeper 승인 요청을 거부했습니다'
    showToast(message, 'success')
    await refreshGate({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'keeper 승인 요청을 처리하지 못했습니다'
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
    await deleteGateApprovalRule(id)
    showToast('Always 규칙을 삭제했습니다', 'success')
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

export async function setKeeperGateMode(mode: GateMode) {
  gateApprovalActing.value = GATE_MODE_ACTING_KEY
  try {
    await setGateMode(mode)
    const label = mode === 'manual' ? 'Human' : mode === 'auto_judge' ? 'Auto Judge' : 'Always Allow'
    showToast(`Gate 모드를 ${label}(으)로 전환했습니다`, 'success')
    await refreshGate({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Gate 모드를 변경하지 못했습니다'
    gateError.value = message
    showToast(message, 'error')
  } finally {
    gateApprovalActing.value = null
  }
}

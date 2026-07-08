import { showToast } from './common/toast'
import {
  deleteGovernanceApprovalRule,
  decideGovernanceExecutionOrder,
  resolveGovernanceApproval,
  setApprovalMode,
  submitGovernanceCaseBrief,
  submitGovernancePetition,
} from '../api/dashboard-governance'
import type { ApprovalMode } from '../types'
import { getSelectedDecision } from './governance-utils'
import { refreshGovernance, selectDecision } from './governance-refresh'
import {
  governanceStarting,
  governanceActing,
  governanceBriefSubmitting,
  governanceApprovalActing,
  governanceError,
  governanceTopicInput,
  governanceBriefInput,
  governanceBriefStance,
  governanceData,
  selectedDecisionKey,
  selectedCaseDetail,
} from './governance-signals'
export { refreshGovernance, selectDecision }

export async function submitPetition() {
  const title = governanceTopicInput.value.trim()
  if (!title) return
  governanceStarting.value = true
  try {
    const created = await submitGovernancePetition(title)
    governanceTopicInput.value = ''
    showToast(created?.case.id ? `청원을 접수했습니다: ${created.case.id}` : '청원을 접수했습니다', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : '청원 접수에 실패했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceStarting.value = false
  }
}

export async function submitBrief() {
  const items = governanceData.value?.items ?? []
  const item = getSelectedDecision(selectedDecisionKey.value, items)
  const summary = governanceBriefInput.value.trim()
  if (!item || !summary) return
  governanceBriefSubmitting.value = true
  try {
    const bundle = await submitGovernanceCaseBrief(item.id, governanceBriefStance.value, summary)
    governanceBriefInput.value = ''
    selectedCaseDetail.value = bundle
    showToast('심의 의견을 기록했습니다', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : '심의 기록에 실패했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceBriefSubmitting.value = false
  }
}

export async function respondToExecutionOrder(decision: 'confirm' | 'deny') {
  const items = governanceData.value?.items ?? []
  const item = getSelectedDecision(selectedDecisionKey.value, items)
  if (!item) return
  governanceActing.value = true
  try {
    await decideGovernanceExecutionOrder(item.id, decision)
    showToast(decision === 'confirm' ? '집행을 승인했습니다' : '집행을 거부했습니다', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : '집행 결정을 처리하지 못했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceActing.value = false
  }
}

export async function respondToKeeperApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule = false,
) {
  if (!id) return
  governanceApprovalActing.value = id
  try {
    await resolveGovernanceApproval(id, decision, rememberRule)
    const message =
      decision === 'approve'
        ? (rememberRule ? 'keeper 승인 요청을 승인하고 Always 규칙을 저장했습니다' : 'keeper 승인 요청을 승인했습니다')
        : 'keeper 승인 요청을 거부했습니다'
    showToast(message, 'success')
    await refreshGovernance({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'keeper 승인 요청을 처리하지 못했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceApprovalActing.value = null
  }
}

export async function deleteKeeperApprovalRule(id: string) {
  if (!id) return
  governanceApprovalActing.value = `rule:${id}`
  try {
    await deleteGovernanceApprovalRule(id)
    showToast('Always 규칙을 삭제했습니다', 'success')
    await refreshGovernance({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Always 규칙을 삭제하지 못했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceApprovalActing.value = null
  }
}

// Busy-state key for the RFC-0319 approval-mode toggle. Distinct from the
// per-approval and per-rule keys so the toggle disables independently.
export const APPROVAL_MODE_ACTING_KEY = 'approval-mode'

export async function setKeeperApprovalMode(mode: ApprovalMode) {
  governanceApprovalActing.value = APPROVAL_MODE_ACTING_KEY
  try {
    await setApprovalMode(mode)
    showToast(
      mode === 'auto_low_risk'
        ? '자동 승인 모드(low-risk)를 켰습니다'
        : '수동 결재 모드로 전환했습니다',
      'success',
    )
    await refreshGovernance({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : '자동 승인 모드를 변경하지 못했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceApprovalActing.value = null
  }
}

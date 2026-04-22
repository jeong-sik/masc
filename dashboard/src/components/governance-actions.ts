import { showToast } from './common/toast'
import {
  deleteGovernanceApprovalRule,
  decideGovernanceExecutionOrder,
  fetchDashboardGovernance,
  fetchGovernanceCaseStatus,
  resolveGovernanceApproval,
  submitGovernanceCaseBrief,
  submitGovernancePetition,
} from '../api'
import { registerGovernanceRefresh } from '../sse-store'
import type { GovernanceDecisionItem } from '../types'
import { filteredItemsByFilter, getSelectedDecision, itemKey } from './governance-utils'
import {
  governanceResource,
  governanceStarting,
  governanceActing,
  governanceBriefSubmitting,
  governanceApprovalActing,
  governanceError,
  governanceTopicInput,
  governanceBriefInput,
  governanceBriefStance,
  governanceFilter,
  governanceData,
  selectedDecisionKey,
  selectedCaseDetail,
  detailLoading,
} from './governance-signals'

async function loadDecisionDetail(item: GovernanceDecisionItem | null) {
  selectedCaseDetail.value = null
  if (!item) return
  detailLoading.value = true
  governanceError.value = ''
  try {
    selectedCaseDetail.value = await fetchGovernanceCaseStatus(item.id)
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : '거버넌스 상세를 불러오지 못했습니다'
  } finally {
    detailLoading.value = false
  }
}

export async function selectDecision(item: GovernanceDecisionItem) {
  selectedDecisionKey.value = itemKey(item)
  await loadDecisionDetail(item)
}

export async function refreshGovernance() {
  governanceError.value = ''
  await governanceResource.load(async () => {
    const data = await fetchDashboardGovernance()
    const items = filteredItemsByFilter(governanceFilter.value, data.items ?? [])
    const current = selectedDecisionKey.value
    const next = items.find(item => itemKey(item) === current) ?? items[0] ?? null
    selectedDecisionKey.value = next ? itemKey(next) : null
    await loadDecisionDetail(next)
    return data
  })
  const s = governanceResource.state.value
  if (s.status === 'error') {
    governanceError.value = s.message
  }
}

registerGovernanceRefresh(refreshGovernance)

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
    await refreshGovernance()
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
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Always 규칙을 삭제하지 못했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceApprovalActing.value = null
  }
}

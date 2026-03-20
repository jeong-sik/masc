import { signal } from '@preact/signals'
import { showToast } from './common/toast'
import {
  decideGovernanceExecutionOrder,
  fetchDashboardGovernance,
  fetchGovernanceCaseStatus,
  fetchRuntimeParams,
  submitGovernanceCaseBrief,
  submitGovernancePetition,
} from '../api'
import type { RuntimeParam, RuntimeParamsSurface } from '../api'
import { registerGovernanceRefresh } from '../sse-store'
import type {
  DashboardGovernanceResponse,
  GovernanceCaseBundle,
  GovernanceDecisionItem,
} from '../types'
import { type GovernanceFilter, filteredItemsByFilter, getSelectedDecision, itemKey } from './governance-utils'

export const governanceLoading = signal(false)
export const governanceStarting = signal(false)
export const governanceActing = signal(false)
export const governanceBriefSubmitting = signal(false)
export const governanceError = signal('')
export const governanceTopicInput = signal('')
export const governanceBriefInput = signal('')
export const governanceBriefStance = signal<'support' | 'oppose' | 'neutral'>('support')
export const governanceFilter = signal<GovernanceFilter>('open')
export const governanceData = signal<DashboardGovernanceResponse | null>(null)
export const selectedDecisionKey = signal<string | null>(null)
export const selectedCaseDetail = signal<GovernanceCaseBundle | null>(null)
export const detailLoading = signal(false)

export const runtimeParams = signal<RuntimeParam[]>([])
export const runtimeSurfaces = signal<RuntimeParamsSurface[]>([])
export const runtimeLoading = signal(false)

// ── Async actions ────────────────────────

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
  governanceLoading.value = true
  governanceError.value = ''
  try {
    const data = await fetchDashboardGovernance()
    governanceData.value = data
    const items = filteredItemsByFilter(governanceFilter.value, data.items ?? [])
    const current = selectedDecisionKey.value
    const next = items.find(item => itemKey(item) === current) ?? items[0] ?? null
    selectedDecisionKey.value = next ? itemKey(next) : null
    await loadDecisionDetail(next)
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : '거버넌스 상태를 불러오지 못했습니다'
  } finally {
    governanceLoading.value = false
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

export async function loadRuntimeParams() {
  runtimeLoading.value = true
  try {
    const data = await fetchRuntimeParams()
    runtimeParams.value = data.parameters ?? []
    runtimeSurfaces.value = data.surfaces ?? []
  } catch {
    // silent -- params panel is optional
  } finally {
    runtimeLoading.value = false
  }
}

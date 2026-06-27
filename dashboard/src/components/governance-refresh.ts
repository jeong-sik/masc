import {
  fetchDashboardGovernance,
  fetchGovernanceCaseStatus,
} from '../api/dashboard-governance'
import { registerGovernanceRefresh } from '../sse-store'
import type { GovernanceDecisionItem } from '../types'
import { filteredItemsByFilter, getSelectedDecision, itemKey } from './governance-utils'
import {
  governanceResource,
  governanceError,
  governanceFilter,
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

export async function refreshGovernance(opts?: { force?: boolean }) {
  governanceError.value = ''
  await governanceResource.load(async (signal) => {
    const data = await fetchDashboardGovernance({ force: opts?.force, signal })
    const items = filteredItemsByFilter(governanceFilter.value, data.items ?? [])
    const current = selectedDecisionKey.value
    const next = getSelectedDecision(current, items) ?? items[0] ?? null
    selectedDecisionKey.value = next ? itemKey(next) : null
    await loadDecisionDetail(next)
    return data
  })
  const s = governanceResource.state.value
  if (s.error) {
    governanceError.value = s.error
  }
}

registerGovernanceRefresh(refreshGovernance)

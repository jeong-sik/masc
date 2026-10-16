import {
  skillAsyncOccurrenceIdentity,
  type DashboardSkillAsyncAction,
  type DashboardSkillAsyncResultDelivery,
} from '../api/dashboard-tools-prompts'

export interface SkillAsyncEvidenceView {
  resultDeliveries: readonly DashboardSkillAsyncResultDelivery[]
  actionLinkCount: number
  actions: readonly {
    first: DashboardSkillAsyncAction
    additionalLinks: readonly DashboardSkillAsyncAction[]
  }[]
}

/** Input has passed the canonical async-evidence decoder. Group physical
 * occurrences without discarding any causal link or observation clock. */
export function projectSkillAsyncEvidence(evidence: {
  async_result_deliveries: readonly DashboardSkillAsyncResultDelivery[]
  async_actions: readonly DashboardSkillAsyncAction[]
}): SkillAsyncEvidenceView {
  const groups = new Map<string, { first: DashboardSkillAsyncAction; additionalLinks: DashboardSkillAsyncAction[] }>()
  for (const action of evidence.async_actions) {
    const key = skillAsyncOccurrenceIdentity(action)
    const group = groups.get(key)
    if (group) groups.set(key, { first: group.first, additionalLinks: [...group.additionalLinks, action] })
    else groups.set(key, { first: action, additionalLinks: [] })
  }
  return {
    resultDeliveries: evidence.async_result_deliveries,
    actionLinkCount: evidence.async_actions.length,
    actions: [...groups.values()],
  }
}

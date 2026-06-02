import type { GoalTaskSummary, GoalTreeNode } from '../../types'

type GoalTaskSummaryNode = Pick<GoalTreeNode, 'task_count' | 'task_done_count' | 'tasks' | 'task_summary'>

function countBy<T extends string>(values: readonly T[]): Record<string, number> {
  const counts: Record<string, number> = {}
  for (const value of values) counts[value] = (counts[value] ?? 0) + 1
  return counts
}

export function goalTaskSummaryForNode(node: GoalTaskSummaryNode): GoalTaskSummary {
  if (node.task_summary) return node.task_summary

  const total = node.task_count
  const done = node.task_done_count
  const terminal = node.tasks.filter(task => task.is_terminal).length
  const awaitingVerification = node.tasks.filter(task => task.status === 'awaiting_verification').length
  const cancelled = node.tasks.filter(task => task.status === 'cancelled').length
  const unassigned = node.tasks.filter(task => !task.assignee).length

  return {
    total,
    done,
    open: Math.max(0, total - terminal),
    terminal,
    awaiting_verification: awaitingVerification,
    cancelled,
    unassigned,
    completion_pct: total > 0 ? Math.floor(done / total * 100) : null,
    by_status: countBy(node.tasks.map(task => task.status)),
    by_linkage_source: countBy(node.tasks.map(task => task.linkage_source)),
  }
}

export function goalTaskCompletionLabel(summary: GoalTaskSummary): string {
  if (summary.total === 0) return '0 linked'
  const pct = summary.completion_pct == null ? 'unmeasured' : `${summary.completion_pct}%`
  return `${summary.done}/${summary.total} done · ${pct}`
}

export function goalTaskLinkageLabel(summary: GoalTaskSummary): string {
  const explicit = summary.by_linkage_source.explicit ?? 0
  if (summary.total === 0) return 'no task links'
  if (explicit === summary.total) return 'explicit goal_id'
  return `${explicit}/${summary.total} explicit`
}

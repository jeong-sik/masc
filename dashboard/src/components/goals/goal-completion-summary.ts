import type { GoalCompletionSummary, GoalTreeNode } from '../../types'

import { goalTaskSummaryForNode } from './goal-task-summary'

type GoalCompletionSummaryNode = Pick<
  GoalTreeNode,
  | 'attainment'
  | 'completion_summary'
  | 'phase'
  | 'task_count'
  | 'task_done_count'
  | 'task_summary'
  | 'tasks'
>

function completionStateForNode(
  node: GoalCompletionSummaryNode,
  taskDone: number,
  pct: number | null,
): string {
  switch (node.phase) {
    case 'completed': return 'completed'
    case 'dropped': return 'dropped'
    case 'blocked': return 'blocked'
    case 'paused': return 'paused'
    default:
      if (node.task_count === 0 && pct == null) return 'unmeasured'
      if (taskDone === 0) return 'not_started'
      return 'in_progress'
  }
}

export function goalCompletionSummaryForNode(node: GoalCompletionSummaryNode): GoalCompletionSummary {
  if (node.completion_summary) return node.completion_summary

  const taskSummary = goalTaskSummaryForNode(node)
  const attainmentPct = node.attainment.attainment_pct
  const pct = attainmentPct ?? taskSummary.completion_pct
  const state = completionStateForNode(node, taskSummary.done, pct)

  return {
    state,
    pct,
    pct_source: attainmentPct != null ? 'attainment' : taskSummary.completion_pct != null ? 'task_summary' : 'none',
    attainment_state: node.attainment.state,
    attainment_basis: node.attainment.basis,
    metric_evaluation: node.attainment.metric_evaluation,
    task_total: taskSummary.total,
    task_done: taskSummary.done,
    task_open: taskSummary.open,
    is_complete: node.phase === 'completed',
    is_terminal: node.phase === 'completed' || node.phase === 'dropped',
    ready_to_request_completion: false,
  }
}

export function goalCompletionLabel(summary: GoalCompletionSummary): string {
  switch (summary.state) {
    case 'completed': return 'completed'
    case 'ready_for_completion': return 'ready for completion'
    case 'blocked': return 'blocked'
    case 'paused': return 'paused'
    case 'dropped': return 'dropped'
    case 'not_started': return 'not started'
    case 'unmeasured': return 'unmeasured'
    default: return 'in progress'
  }
}

export function goalCompletionTone(summary: GoalCompletionSummary): 'default' | 'ok' | 'warn' | 'bad' {
  switch (summary.state) {
    case 'completed': return 'ok'
    case 'ready_for_completion':
    case 'paused':
    case 'unmeasured':
      return 'warn'
    case 'blocked':
    case 'dropped':
      return 'bad'
    default:
      return 'default'
  }
}

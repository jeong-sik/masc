import type { GoalCompletionSummary, GoalTreeNode } from '../../types'

import { goalTaskSummaryForNode } from './goal-task-summary'

type GoalCompletionSummaryNode = Pick<
  GoalTreeNode,
  | 'attainment'
  | 'blocking_reason'
  | 'blocking_source'
  | 'completion_summary'
  | 'phase'
  | 'require_completion_approval'
  | 'task_count'
  | 'task_done_count'
  | 'task_summary'
  | 'tasks'
  | 'verification_summary'
>

function completionStateForNode(
  node: GoalCompletionSummaryNode,
  taskOpen: number,
  taskDone: number,
  pct: number | null,
): string {
  switch (node.phase) {
    case 'completed': return 'completed'
    case 'dropped': return 'dropped'
    case 'blocked': return 'blocked'
    case 'paused': return 'paused'
    case 'awaiting_verification': return 'awaiting_verification'
    case 'awaiting_approval': return 'awaiting_approval'
    default:
      if (
        node.attainment.metric_evaluation !== 'unevaluated'
        && (node.attainment.state === 'attained' || (node.task_count > 0 && taskOpen === 0 && taskDone > 0))
      ) {
        return 'ready_for_completion'
      }
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
  const openRequest = node.verification_summary.open_request != null
  const gate =
    node.phase === 'awaiting_verification' || openRequest ? 'verification'
    : node.phase === 'awaiting_approval' ? 'approval'
    : 'none'
  const state = completionStateForNode(node, taskSummary.open, taskSummary.done, pct)

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
    ready_to_request_completion: state === 'ready_for_completion',
    gate,
    requires_verifier: node.verification_summary.effective_policy != null,
    requires_completion_approval: node.require_completion_approval,
    active_verification_request: openRequest,
    blocking_source: node.blocking_source,
    blocking_reason: node.blocking_reason,
  }
}

export function goalCompletionLabel(summary: GoalCompletionSummary): string {
  switch (summary.state) {
    case 'completed': return 'completed'
    case 'ready_for_completion': return 'ready for completion'
    case 'awaiting_verification': return 'awaiting verification'
    case 'awaiting_approval': return 'awaiting approval'
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
    case 'awaiting_verification':
    case 'awaiting_approval':
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

export function goalCompletionGateLabel(summary: GoalCompletionSummary): string {
  if (summary.gate === 'verification') return 'verification gate'
  if (summary.gate === 'approval') return 'approval gate'
  if (summary.requires_verifier) return 'verifier policy'
  if (summary.requires_completion_approval) return 'approval required'
  return 'direct completion'
}

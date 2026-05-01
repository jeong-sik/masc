// Ops helpers — shared view helpers built on top of the canonical ops state.

import { showToast } from '../common/toast'
import { prettyJson, displayStatus } from '../../lib/status-label'
import type { OperatorKeeperSnapshot } from '../../types'
import { dispatchOperatorAction } from '../../operator-store'
import { workflowActionLabel, type DashboardWorkflowContext } from '../../workflow-context'
import {
  actorName,
  broadcastMessage,
  pauseReason,
  taskTitle,
  taskDescription,
  taskPriority,
  selectedKeeperName,
  keeperMessage,
  hydratedWorkflowId,
  persistActorName,
} from './ops-state'

export {
  actorName,
  broadcastMessage,
  pauseReason,
  taskTitle,
  taskDescription,
  taskPriority,
  selectedKeeperName,
  keeperMessage,
  hydratedWorkflowId,
  persistActorName,
}

export { prettyJson, displayStatus }

export function normalizeStatus(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

function canonicalizeActionType(value?: string | null): string | null {
  if (!value) return null
  const normalized = value.trim()
  if (normalized === 'keeper_msg') return 'keeper_message'
  return normalized
}

export function actionTypeLabel(value?: string | null): string {
  const label = workflowActionLabel(value)
  return label === 'Recommended Action' ? 'Action' : label
}

export function targetTypeLabel(value?: string | null): string {
  switch (value) {
    case 'task':
      return 'Task'
    case 'namespace':
      return 'Namespace'
    case 'room':
      return 'Namespace'
    case 'keeper':
      return 'Keeper'
    case 'swarm_run':
      return 'Swarm Run'
    default:
      return value?.trim() || 'Target'
  }
}

export function isRootTarget(value?: string | null): boolean {
  return value === 'root' || value === 'namespace' || value === 'room'
}
const isNamespaceTarget = isRootTarget

function workflowPayloadString(
  payload: Record<string, unknown> | null | undefined,
  key: string,
): string | null {
  if (!payload) return null
  const value = payload[key]
  if (typeof value === 'string' && value.trim() !== '') return value.trim()
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
}

function payloadRecord(payload: unknown): Record<string, unknown> | null {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null
  return payload as Record<string, unknown>
}

function hydrateActionForm(input: {
  action_type?: string | null
  target_type?: string | null
  target_id?: string | null
  payload?: unknown
  summary: string
}): void {
  const payload = payloadRecord(input.payload)
  const actionType = canonicalizeActionType(input.action_type)
  if (isNamespaceTarget(input.target_type)) {
    if (actionType === 'broadcast') {
      broadcastMessage.value = workflowPayloadString(payload, 'message') ?? input.summary
      return
    }
    if (actionType === 'task_inject') {
      taskTitle.value = workflowPayloadString(payload, 'title') ?? 'Operator-injected task'
      taskDescription.value = workflowPayloadString(payload, 'description') ?? input.summary
      taskPriority.value = workflowPayloadString(payload, 'priority') ?? taskPriority.value
      return
    }
    if (actionType === 'namespace_pause' || actionType === 'room_pause') {
      pauseReason.value = workflowPayloadString(payload, 'reason') ?? input.summary
    }
    return
  }

  if (input.target_type === 'keeper') {
    if (input.target_id) selectedKeeperName.value = input.target_id
    keeperMessage.value = workflowPayloadString(payload, 'message') ?? input.summary
  }
}

export function hydrateOpsWorkflow(context: DashboardWorkflowContext): void {
  hydrateActionForm({
    action_type: context.action_type,
    target_type: context.target_type,
    target_id: context.target_id,
    payload: context.suggested_payload,
    summary: context.summary,
  })
}

export function workflowTargetReady(
  context: DashboardWorkflowContext | null,
  keepers: OperatorKeeperSnapshot[],
): boolean {
  if (!context) return true
  if (!context.target_type || isNamespaceTarget(context.target_type)) return true
  if (context.target_type === 'keeper') {
    return !!context.target_id && keepers.some(keeper => keeper.name === context.target_id)
  }
  return true
}

export async function executeAction(input: {
  action_type: string
  target_type: 'root' | 'namespace' | 'room' | 'keeper' | string
  target_id?: string
  payload: Record<string, unknown>
  successMessage: string
}) {
  const actor = actorName.value.trim() || 'dashboard'
  try {
    const result = await dispatchOperatorAction({
      actor,
      action_type: input.action_type,
      target_type: input.target_type,
      target_id: input.target_id,
      payload: input.payload,
    })
    if (result.confirm_required) {
      showToast('Queued for confirmation.', 'warning')
    } else {
      showToast(input.successMessage, 'success')
    }
    return result
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Intervention failed.'
    showToast(message, 'error')
    return null
  }
}

/** Format message content for human readability.
 *  Replaces raw session/task IDs with readable labels. */
export function formatMessageContent(content: string): string {
  if (!content) return ''
  return content
    .replace(/\[team-session:ts-\d+-\w+\.\.\./g, '[session ')
    .replace(/\[team-session:([^\]]{0,20})[^\]]*\]/g, '[session $1]')
    .replace(/ts-\d{13,}-[a-f0-9]{4,8}/g, (match) => {
      const ts = match.match(/ts-(\d{13,})/)
      const tsValue = ts?.[1]
      if (tsValue) {
        const date = new Date(parseInt(tsValue, 10))
        return date.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
      }
      return match
    })
}

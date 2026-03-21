import { showToast } from '../common/toast'
import type {
  OperatorKeeperSnapshot,
  OperatorRecommendedAction,
  OperatorSessionSnapshot,
} from '../../types'
import type { DashboardWorkflowContext } from '../../workflow-context'
import { prettyJson } from './helpers'
import {
  broadcastMessage,
  keeperMessage,
  pauseReason,
  selectedKeeperName,
  selectedSessionId,
  taskDescription,
  taskPriority,
  taskTitle,
  teamMessage,
  teamSpawnBatchJson,
  teamStopReason,
  teamTaskDescription,
  teamTaskPriority,
  teamTaskTitle,
  teamTurnKind,
} from './ops-state'

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

function spawnBatchJsonString(payload: Record<string, unknown> | null): string {
  if (!payload) return ''
  const direct = payload.spawn_batch
  if (direct !== undefined) return prettyJson(direct)
  return prettyJson(payload)
}

function hydrateActionForm(input: {
  action_type?: string | null
  target_type?: string | null
  target_id?: string | null
  payload?: unknown
  summary: string
}): void {
  const payload = payloadRecord(input.payload)
  if (input.target_type === 'room') {
    if (input.action_type === 'broadcast') {
      broadcastMessage.value = workflowPayloadString(payload, 'message') ?? input.summary
      return
    }
    if (input.action_type === 'task_inject') {
      taskTitle.value = workflowPayloadString(payload, 'title') ?? '운영자 주입 작업'
      taskDescription.value = workflowPayloadString(payload, 'description') ?? input.summary
      taskPriority.value = workflowPayloadString(payload, 'priority') ?? taskPriority.value
      return
    }
    if (input.action_type === 'room_pause') {
      pauseReason.value = workflowPayloadString(payload, 'reason') ?? input.summary
    }
    return
  }

  if (input.target_type === 'team_session') {
    if (input.target_id) selectedSessionId.value = input.target_id
    if (input.action_type === 'team_stop') {
      teamStopReason.value = workflowPayloadString(payload, 'reason') ?? input.summary
      return
    }
    teamTurnKind.value =
      input.action_type === 'team_worker_spawn_batch'
        ? 'worker_spawn_batch'
        : input.action_type === 'team_task_inject'
          ? 'task'
          : input.action_type === 'team_broadcast'
            ? 'broadcast'
            : 'note'
    const message = workflowPayloadString(payload, 'message')
    if (message) teamMessage.value = message
    if (teamTurnKind.value === 'worker_spawn_batch') {
      teamSpawnBatchJson.value = spawnBatchJsonString(payload)
      return
    }
    if (teamTurnKind.value === 'task') {
      teamTaskTitle.value = workflowPayloadString(payload, 'task_title')
        ?? workflowPayloadString(payload, 'title')
        ?? '운영자 주입 작업'
      teamTaskDescription.value = workflowPayloadString(payload, 'task_description')
        ?? workflowPayloadString(payload, 'description')
        ?? input.summary
      teamTaskPriority.value = workflowPayloadString(payload, 'task_priority')
        ?? workflowPayloadString(payload, 'priority')
        ?? teamTaskPriority.value
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

export function hydrateRecommendedAction(item: OperatorRecommendedAction): void {
  hydrateActionForm({
    action_type: item.action_type,
    target_type: item.target_type,
    target_id: item.target_id ?? null,
    payload: item.suggested_payload,
    summary: item.reason,
  })
  showToast('추천 액션 payload를 폼에 채웠습니다', 'success')
}

export function workflowTargetReady(
  context: DashboardWorkflowContext | null,
  sessions: OperatorSessionSnapshot[],
  keepers: OperatorKeeperSnapshot[],
): boolean {
  if (!context) return true
  if (!context.target_type || context.target_type === 'room') return true
  if (context.target_type === 'team_session') {
    return !!context.target_id && sessions.some(session => session.session_id === context.target_id)
  }
  if (context.target_type === 'keeper') {
    return !!context.target_id && keepers.some(keeper => keeper.name === context.target_id)
  }
  return true
}

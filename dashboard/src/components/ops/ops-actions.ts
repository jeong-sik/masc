import { showToast } from '../common/toast'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorSnapshot,
} from '../../operator-store'
import { pickPreferredSession } from './helpers'
import {
  actorName,
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

type OperatorActionType =
  | 'broadcast'
  | 'room_pause'
  | 'room_resume'
  | 'task_inject'
  | 'team_note'
  | 'team_broadcast'
  | 'team_task_inject'
  | 'team_worker_spawn_batch'
  | 'team_stop'
  | 'keeper_message'

type OperatorTargetType = 'room' | 'team_session' | 'keeper'

function resolveSelectedSessionId(sessionIds: { session_id: string }[]): string {
  if (
    selectedSessionId.value
    && sessionIds.some(session => session.session_id === selectedSessionId.value)
  ) {
    return selectedSessionId.value
  }
  return pickPreferredSession(sessionIds)?.session_id ?? ''
}

async function executeAction(input: {
  action_type: OperatorActionType
  target_type: OperatorTargetType
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
      showToast('확인 대기열에 올렸습니다', 'warning')
    } else {
      showToast(input.successMessage, 'success')
    }
    return result
  } catch (err) {
    const message = err instanceof Error ? err.message : '개입 실행에 실패했습니다'
    showToast(message, 'error')
    return null
  }
}

export async function submitBroadcast() {
  const message = broadcastMessage.value.trim()
  if (!message) return
  const result = await executeAction({
    action_type: 'broadcast',
    target_type: 'room',
    payload: { message },
    successMessage: '방송을 보냈습니다',
  })
  if (result) broadcastMessage.value = ''
}

export async function submitPause() {
  await executeAction({
    action_type: 'room_pause',
    target_type: 'room',
    payload: { reason: pauseReason.value.trim() || '운영 점검' },
    successMessage: '방 일시정지를 요청했습니다',
  })
}

export async function submitResume() {
  await executeAction({
    action_type: 'room_resume',
    target_type: 'room',
    payload: {},
    successMessage: '방 재개를 요청했습니다',
  })
}

export async function submitTaskInject() {
  const title = taskTitle.value.trim()
  if (!title) return
  const result = await executeAction({
    action_type: 'task_inject',
    target_type: 'room',
    payload: {
      title,
      description: taskDescription.value.trim() || '개입 화면에서 주입',
      priority: Number.parseInt(taskPriority.value, 10) || 2,
    },
    successMessage: '작업 주입을 보냈습니다',
  })
  if (result) {
    taskTitle.value = ''
    taskDescription.value = ''
  }
}

export async function submitTeamTurn() {
  const snapshot = operatorSnapshot.value
  const sessionId = resolveSelectedSessionId(snapshot?.sessions ?? [])
  if (!sessionId) {
    showToast('먼저 세션을 고르세요', 'warning')
    return
  }
  const payload: Record<string, unknown> = {}
  if (teamTurnKind.value === 'worker_spawn_batch') {
    const raw = teamSpawnBatchJson.value.trim()
    if (!raw) {
      showToast('spawn_batch JSON을 먼저 채우세요', 'warning')
      return
    }
    try {
      const parsed = JSON.parse(raw) as unknown
      if (Array.isArray(parsed)) {
        payload.spawn_batch = parsed
      } else if (
        parsed
        && typeof parsed === 'object'
        && Array.isArray((parsed as Record<string, unknown>).spawn_batch)
      ) {
        payload.spawn_batch = (parsed as Record<string, unknown>).spawn_batch
      } else {
        showToast('spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다', 'warning')
        return
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : 'spawn_batch JSON 파싱에 실패했습니다'
      showToast(message, 'error')
      return
    }
    const result = await executeAction({
      action_type: 'team_worker_spawn_batch',
      target_type: 'team_session',
      target_id: sessionId,
      payload,
      successMessage: '작업자 교체 요청을 적용했습니다',
    })
    if (result) teamSpawnBatchJson.value = ''
    return
  }
  const message = teamMessage.value.trim()
  if (message) payload.message = message
  let actionType: 'team_note' | 'team_broadcast' | 'team_task_inject' = 'team_note'
  if (teamTurnKind.value === 'broadcast') {
    actionType = 'team_broadcast'
  } else if (teamTurnKind.value === 'task') {
    actionType = 'team_task_inject'
  }
  if (teamTurnKind.value === 'task') {
    payload.task_title = teamTaskTitle.value.trim() || '운영자 주입 작업'
    payload.task_description = teamTaskDescription.value.trim() || '개입 화면에서 주입'
    payload.task_priority = Number.parseInt(teamTaskPriority.value, 10) || 2
  }
  const result = await executeAction({
    action_type: actionType,
    target_type: 'team_session',
    target_id: sessionId,
    payload,
    successMessage: '세션 액션을 적용했습니다',
  })
  if (result) {
    teamMessage.value = ''
    if (teamTurnKind.value === 'task') {
      teamTaskTitle.value = ''
      teamTaskDescription.value = ''
    }
  }
}

export async function submitTeamStop() {
  const snapshot = operatorSnapshot.value
  const sessionId = resolveSelectedSessionId(snapshot?.sessions ?? [])
  if (!sessionId) {
    showToast('먼저 세션을 고르세요', 'warning')
    return
  }
  await executeAction({
    action_type: 'team_stop',
    target_type: 'team_session',
    target_id: sessionId,
    payload: { reason: teamStopReason.value.trim() || '운영자 중지 요청' },
    successMessage: '세션 중지를 요청했습니다',
  })
}

export async function submitKeeperMessage() {
  const snapshot = operatorSnapshot.value
  const keeperName = selectedKeeperName.value || snapshot?.keepers[0]?.name || ''
  const message = keeperMessage.value.trim()
  if (!keeperName) {
    showToast('먼저 키퍼를 고르세요', 'warning')
    return
  }
  if (!message) return
  const result = await executeAction({
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: keeperName,
    payload: { message },
    successMessage: `${keeperName}에게 메시지를 보냈습니다`,
  })
  if (result) keeperMessage.value = ''
}

export async function confirmPending(
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
) {
  const actor = actorName.value.trim() || 'dashboard'
  try {
    await confirmOperatorPendingAction(actor, confirmToken, decision)
    showToast(
      decision === 'deny' ? '승인 대기를 거부했습니다' : '확인 실행을 완료했습니다',
      'success',
    )
  } catch (err) {
    const message = err instanceof Error
      ? err.message
      : decision === 'deny'
        ? '승인 대기 거부에 실패했습니다'
        : '확인 실행에 실패했습니다'
    showToast(message, 'error')
  }
}

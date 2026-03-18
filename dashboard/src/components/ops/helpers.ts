// Ops helpers — signals, types, utilities, action dispatch

import { signal } from '@preact/signals'
import { showToast } from '../common/toast'
import { prettyJson, displayStatus } from '../../lib/status-label'
import type {
  OperatorAttentionItem,
  OperatorGuidanceSummary,
  OperatorKeeperSnapshot,
  OperatorRecommendedAction,
  OperatorResidentJudgeRuntime,
  OperatorSessionSnapshot,
} from '../../types'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorSnapshot,
} from '../../operator-store'
import type { DashboardWorkflowContext } from '../../workflow-context'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

function initialActorName(): string {
  const params = new URLSearchParams(window.location.search)
  return (
    params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || localStorage.getItem(AGENT_NAME_KEY)?.trim()
    || 'dashboard'
  )
}

export const actorName = signal(initialActorName())
export const broadcastMessage = signal('')
export const pauseReason = signal('운영 점검')
export const taskTitle = signal('')
export const taskDescription = signal('')
export const taskPriority = signal('2')
export const selectedSessionId = signal('')
export const teamTurnKind = signal<'note' | 'broadcast' | 'task' | 'worker_spawn_batch'>('note')
export const teamMessage = signal('')
export const teamTaskTitle = signal('')
export const teamTaskDescription = signal('')
export const teamTaskPriority = signal('2')
export const teamSpawnBatchJson = signal('')
export const teamStopReason = signal('운영자 중지 요청')
export const selectedKeeperName = signal('')
export const keeperMessage = signal('')
export const hydratedWorkflowId = signal<string | null>(null)

export function persistActorName(value: string): void {
  const trimmed = value.trim() || 'dashboard'
  actorName.value = trimmed
  localStorage.setItem(AGENT_NAME_KEY, trimmed)
}

export { prettyJson, displayStatus }

export function guidanceLayerLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'judgment':
      return '상주 판단'
    case 'fallback':
      return '보조 읽기 모델'
    default:
      return value?.trim() || '안내'
  }
}

export function guidanceLayerTone(value?: string | null): OpsPriorityTone {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'judgment':
      return 'ok'
    case 'fallback':
      return 'warn'
    default:
      return 'warn'
  }
}

export function runtimeJudgeLabel(runtime?: OperatorResidentJudgeRuntime | null): string {
  if (!runtime?.enabled) return '꺼짐'
  if (runtime.refreshing) return '갱신 중'
  if (runtime.judge_online) return '온라인'
  return runtime.last_error ? '오류' : '대기'
}

export function runtimeJudgeTone(runtime?: OperatorResidentJudgeRuntime | null): OpsPriorityTone {
  if (!runtime?.enabled) return 'warn'
  if (runtime.judge_online) return 'ok'
  if (runtime.refreshing) return 'warn'
  return 'bad'
}

export function guidanceFreshnessLabel(summary?: OperatorGuidanceSummary | null): string {
  if (!summary?.fresh_until) return '갱신 기준 없음'
  return summary.fresh_until
}

export function relativeAge(seconds?: number): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return '확인 없음'
  if (seconds < 60) return `${Math.round(seconds)}초 전`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분 전`
  return `${Math.round(seconds / 3600)}시간 전`
}

export type OpsPriorityTone = 'ok' | 'warn' | 'bad'

export interface OpsPriorityCardData {
  key: string
  label: string
  value: string | number
  detail: string
  tone: OpsPriorityTone
}

export function normalizeStatus(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

export function sessionPriorityTone(session: OperatorSessionSnapshot): OpsPriorityTone {
  const status = normalizeStatus(session.status)
  if (status === 'paused') return 'bad'
  if (status === '' || status === 'unknown') return 'warn'
  const health = normalizeStatus(session.team_health?.status)
  if (health && health !== 'ok' && health !== 'healthy' && health !== 'green') return 'warn'
  if (status && status !== 'active' && status !== 'running' && status !== 'ended') return 'warn'
  return 'ok'
}

export function keeperPriorityTone(keeper: OperatorKeeperSnapshot): OpsPriorityTone {
  const status = normalizeStatus(keeper.status)
  if (status === 'offline' || status === 'inactive' || status === 'error') return 'bad'
  if (status === '' || status === 'unknown') return 'warn'
  if ((keeper.context_ratio ?? 0) >= 0.8) return 'warn'
  if (keeper.context_ratio == null) return 'warn'
  if (keeper.last_turn_ago_s == null) return 'warn'
  if ((keeper.last_turn_ago_s ?? 0) >= 3600) return 'warn'
  return 'ok'
}

export function attentionTone(items: OperatorAttentionItem[]): OpsPriorityTone {
  if (items.some(item => normalizeStatus(item.severity) === 'bad')) return 'bad'
  if (items.length > 0) return 'warn'
  return 'ok'
}

export function isSessionAttention(item: OperatorAttentionItem): boolean {
  return item.target_type === 'team_session'
}

export function isKeeperAttention(item: OperatorAttentionItem): boolean {
  return item.target_type === 'keeper'
}

export function actionTypeLabel(value?: string | null): string {
  switch (value) {
    case 'broadcast':
      return '방송'
    case 'room_pause':
      return '방 일시정지'
    case 'room_resume':
      return '방 재개'
    case 'team_turn':
      return '세션 업데이트'
    case 'team_note':
      return '세션 노트'
    case 'team_broadcast':
      return '세션 방송'
    case 'team_task_inject':
      return '세션 작업 주입'
    case 'team_worker_spawn_batch':
      return '세션 작업자 교체'
    case 'task_inject':
      return '작업 주입'
    case 'team_stop':
      return '세션 중지'
    case 'keeper_message':
      return '키퍼 메시지'
    case 'keeper_msg':
      return '키퍼 메시지'
    case 'swarm_run_continue':
      return '스웜 실행 계속'
    case 'swarm_run_rerun':
      return '스웜 실행 재실행'
    case 'swarm_run_abandon':
      return '스웜 실행 포기'
    default:
      return value?.trim() || '액션'
  }
}

export function targetTypeLabel(value?: string | null): string {
  switch (value) {
    case 'room':
      return '방'
    case 'team_session':
      return '세션'
    case 'keeper':
      return '키퍼'
    case 'swarm_run':
      return '스웜 실행'
    default:
      return value?.trim() || '대상'
  }
}

export function deliveryModeLabel(confirmRequired?: boolean): string {
  return confirmRequired ? '확인 후 실행' : '즉시 실행'
}

export function sessionActionLabel(value: typeof teamTurnKind.value): string {
  switch (value) {
    case 'note':
      return '노트'
    case 'broadcast':
      return '방송'
    case 'task':
      return '작업'
    case 'worker_spawn_batch':
      return '작업자 교체'
    default:
      return value
  }
}

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
      teamTaskTitle.value = workflowPayloadString(payload, 'task_title') ?? workflowPayloadString(payload, 'title') ?? '운영자 주입 작업'
      teamTaskDescription.value = workflowPayloadString(payload, 'task_description') ?? workflowPayloadString(payload, 'description') ?? input.summary
      teamTaskPriority.value = workflowPayloadString(payload, 'task_priority') ?? workflowPayloadString(payload, 'priority') ?? teamTaskPriority.value
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

async function executeAction(input: {
  action_type: 'broadcast' | 'room_pause' | 'room_resume' | 'task_inject' | 'team_note' | 'team_broadcast' | 'team_task_inject' | 'team_worker_spawn_batch' | 'team_stop' | 'keeper_message'
  target_type: 'room' | 'team_session' | 'keeper'
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
  const sessionId = selectedSessionId.value || snapshot?.sessions[0]?.session_id || ''
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
      } else if (parsed && typeof parsed === 'object' && Array.isArray((parsed as Record<string, unknown>).spawn_batch)) {
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
  const sessionId = selectedSessionId.value || snapshot?.sessions[0]?.session_id || ''
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
    showToast(decision === 'deny' ? '승인 대기를 거부했습니다' : '확인 실행을 완료했습니다', 'success')
  } catch (err) {
    const message = err instanceof Error
      ? err.message
      : decision === 'deny'
        ? '승인 대기 거부에 실패했습니다'
        : '확인 실행에 실패했습니다'
    showToast(message, 'error')
  }
}

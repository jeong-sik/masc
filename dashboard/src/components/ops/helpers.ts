// Ops helpers — shared view helpers built on top of the canonical ops state.

import { showToast } from '../common/toast'
import { prettyJson, displayStatus } from '../../lib/status-label'
import type {
  OperatorDigest,
  OperatorGuidanceSummary,
  OperatorKeeperSnapshot,
  OperatorReviewItem,
  PendingConfirmation,
  OperatorRecommendedAction,
  OperatorJudgeRuntime,
} from '../../types'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorSnapshot,
} from '../../operator-store'
import type { DashboardWorkflowContext } from '../../workflow-context'
import {
  actorName,
  broadcastMessage,
  pauseReason,
  selectedReviewItemId,
  selectedReviewTab,
  reviewDecisionReason,
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
  selectedReviewItemId,
  selectedReviewTab,
  reviewDecisionReason,
  taskTitle,
  taskDescription,
  taskPriority,
  selectedKeeperName,
  keeperMessage,
  hydratedWorkflowId,
  persistActorName,
}

export { prettyJson, displayStatus }

export function guidanceLayerLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'judgment':
      return '운영 판단'
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

export function runtimeJudgeLabel(runtime?: OperatorJudgeRuntime | null): string {
  if (!runtime?.enabled) return '꺼짐'
  if (runtime.refreshing) return '갱신 중'
  if (runtime.judge_online) return '온라인'
  return runtime.last_error ? '오류' : '대기'
}

export function runtimeJudgeTone(runtime?: OperatorJudgeRuntime | null): OpsPriorityTone {
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
export type KeeperPriorityReason =
  | 'offline'
  | 'unknown_status'
  | 'high_context'
  | 'missing_context'
  | 'missing_turns'
  | 'stale_turns'

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

export function keeperPriorityReasons(keeper: OperatorKeeperSnapshot): KeeperPriorityReason[] {
  const status = normalizeStatus(keeper.status)
  if (status === 'offline' || status === 'inactive' || status === 'error') return ['offline']

  const reasons: KeeperPriorityReason[] = []
  if (status === '' || status === 'unknown') reasons.push('unknown_status')
  if ((keeper.context_ratio ?? 0) >= 0.8) reasons.push('high_context')
  if (keeper.context_ratio == null) reasons.push('missing_context')
  if (keeper.last_turn_ago_s == null) reasons.push('missing_turns')
  if ((keeper.last_turn_ago_s ?? 0) >= 3600) reasons.push('stale_turns')
  return reasons
}

function keeperReasonLabel(reason: KeeperPriorityReason): string {
  switch (reason) {
    case 'offline':
      return '오프라인'
    case 'unknown_status':
      return '상태 미수집'
    case 'high_context':
      return '컨텍스트 80%+'
    case 'missing_context':
      return '컨텍스트 텔레메트리 없음'
    case 'missing_turns':
      return '최근 턴 기록 없음'
    case 'stale_turns':
      return '1시간 이상 비활성'
  }
}

export function keeperPriorityInfo(keeper: OperatorKeeperSnapshot): { tone: OpsPriorityTone; summary: string } {
  const reasons = keeperPriorityReasons(keeper)
  const tone: OpsPriorityTone = reasons.includes('offline') ? 'bad' : reasons.length > 0 ? 'warn' : 'ok'
  const summary = reasons.length === 0 ? '점검 필요 신호 없음' : reasons.map(keeperReasonLabel).join(' · ')
  return { tone, summary }
}

export function keeperPriorityTone(keeper: OperatorKeeperSnapshot): OpsPriorityTone {
  return keeperPriorityInfo(keeper).tone
}

export function keeperPrioritySummary(keeper: OperatorKeeperSnapshot): string {
  return keeperPriorityInfo(keeper).summary
}

export function actionTypeLabel(value?: string | null): string {
  switch (value) {
    case 'broadcast':
      return '전체 공지'
    case 'namespace_pause':
    case 'room_pause':
      return '프로젝트 일시정지'
    case 'namespace_resume':
    case 'room_resume':
      return '프로젝트 재개'
    case 'task_inject':
      return '작업 주입'
    case 'keeper_message':
      return '키퍼 메시지'
    case 'keeper_probe':
      return '키퍼 점검'
    case 'keeper_recover':
      return '키퍼 복구'
    case 'review_resolve':
      return '검토 해결'
    case 'review_defer':
      return '검토 보류'
    default:
      return value?.trim() || '액션'
  }
}

export function targetTypeLabel(value?: string | null): string {
  switch (value) {
    case 'namespace':
      return '프로젝트 범위'
    case 'room':
      return '프로젝트 범위'
    case 'keeper':
      return '키퍼'
    case 'review_item':
      return '리뷰 항목'
    case 'swarm_run':
      return '스웜 실행'
    default:
      return value?.trim() || '대상'
  }
}

function isNamespaceTarget(value?: string | null): boolean {
  return value === 'namespace' || value === 'room'
}

export function deliveryModeLabel(confirmRequired?: boolean): string {
  return confirmRequired ? '확인 후 실행' : '즉시 실행'
}

export type PendingQueueFilter =
  | { kind: 'all' }
  | { kind: 'mine' }
  | { kind: 'actor'; actor: string }

export function filterPendingConfirmations(
  items: PendingConfirmation[],
  currentActor: string,
  filter: PendingQueueFilter,
): PendingConfirmation[] {
  switch (filter.kind) {
    case 'all':
      return items
    case 'mine':
      return items.filter(item => (item.actor ?? '').trim() === currentActor)
    case 'actor':
      return items.filter(item => (item.actor ?? '').trim() === filter.actor)
  }
}

export function canManagePendingConfirmation(
  item: PendingConfirmation,
  currentActor: string,
): boolean {
  return (item.actor ?? '').trim() === currentActor
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

function hydrateActionForm(input: {
  action_type?: string | null
  target_type?: string | null
  target_id?: string | null
  payload?: unknown
  summary: string
}): void {
  const payload = payloadRecord(input.payload)
  if (isNamespaceTarget(input.target_type)) {
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
    if (input.action_type === 'namespace_pause' || input.action_type === 'room_pause') {
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
  action_type: 'broadcast' | 'namespace_pause' | 'namespace_resume' | 'room_pause' | 'room_resume' | 'task_inject' | 'keeper_message' | 'keeper_probe' | 'keeper_recover' | 'review_resolve' | 'review_defer'
  target_type: 'namespace' | 'room' | 'keeper' | 'review_item'
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

export async function submitReviewDecision(
  item: OperatorReviewItem,
  decision: 'review_resolve' | 'review_defer',
) {
  const reason = reviewDecisionReason.value.trim()
  if (!reason) {
    showToast('처리 이유를 먼저 남기세요', 'warning')
    return null
  }
  const result = await executeAction({
    action_type: decision,
    target_type: 'review_item',
    target_id: item.id,
    payload: {
      item_id: item.id,
      fingerprint: item.fingerprint,
      item_target_type: item.target_type,
      item_target_id: item.target_id ?? undefined,
      recommended_action_type: item.recommended_action?.action_type ?? undefined,
      reason,
    },
    successMessage: decision === 'review_resolve' ? '검토 항목을 해결 처리했습니다' : '검토 항목을 보류 처리했습니다',
  })
  if (result) reviewDecisionReason.value = ''
  return result
}

export async function executeRecommendedAction(action: OperatorRecommendedAction) {
  const payload =
    action.suggested_payload && typeof action.suggested_payload === 'object' && !Array.isArray(action.suggested_payload)
      ? action.suggested_payload as Record<string, unknown>
      : {}
  return executeAction({
    action_type: action.action_type as 'broadcast' | 'namespace_pause' | 'namespace_resume' | 'room_pause' | 'room_resume' | 'task_inject' | 'keeper_message' | 'keeper_probe' | 'keeper_recover',
    target_type: action.target_type as 'namespace' | 'room' | 'keeper',
    target_id: action.target_id ?? undefined,
    payload,
    successMessage: `${actionTypeLabel(action.action_type)}을(를) 요청했습니다`,
  })
}

export function primaryActionForReviewItem(item: OperatorReviewItem): OperatorRecommendedAction | null {
  if (item.recommended_action) return item.recommended_action
  if (item.kind === 'namespace_gate' || item.kind === 'room_gate') {
    return {
      action_type: 'namespace_resume',
      target_type: 'namespace',
      target_id: null,
      severity: item.severity,
      reason: item.why_now,
      suggested_payload: {},
    }
  }
  return null
}

export function detailDigestForItem(
  item: OperatorReviewItem | null,
  roomDigest: OperatorDigest | null,
): OperatorDigest | null {
  if (!item) return null
  if (isNamespaceTarget(item.target_type)) return roomDigest
  return null
}

export async function submitBroadcast() {
  const message = broadcastMessage.value.trim()
  if (!message) return
  const result = await executeAction({
    action_type: 'broadcast',
    target_type: 'namespace',
    payload: { message },
    successMessage: '전체 공지를 보냈습니다',
  })
  if (result) broadcastMessage.value = ''
}

export async function submitPause() {
  await executeAction({
    action_type: 'namespace_pause',
    target_type: 'namespace',
    payload: { reason: pauseReason.value.trim() || '운영 점검' },
    successMessage: '프로젝트 일시정지를 요청했습니다',
  })
}

export async function submitResume() {
  await executeAction({
    action_type: 'namespace_resume',
    target_type: 'namespace',
    payload: {},
    successMessage: '프로젝트 재개를 요청했습니다',
  })
}

export async function submitTaskInject() {
  const title = taskTitle.value.trim()
  if (!title) return
  const result = await executeAction({
    action_type: 'task_inject',
    target_type: 'namespace',
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

/** Map log entry severity/outcome to Tailwind border class */
export function logEntryBorderClass(severity?: string | null): string {
  switch (severity) {
    case 'preview': return 'border-[var(--warn-30)]'
    case 'confirmed':
    case 'executed': return 'border-[var(--ok-30)]'
    case 'error': return 'border-[var(--bad-30)]'
    default: return ''
  }
}

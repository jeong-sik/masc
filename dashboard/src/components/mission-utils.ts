import { signal } from '@preact/signals'
import { navigate } from '../router'
import { missionSnapshot } from '../mission-store'
import { findKeeper } from '../lib/keeper-utils'
import type {
  Agent,
  DashboardMissionAttentionQueueItem,
  DashboardMissionAgentBrief,
  DashboardMissionKeeperBrief,
  DashboardMissionSessionBrief,
  Keeper,
  OperatorAttentionItem,
  OperatorRecommendedAction,
} from '../types'
import {
  createMissionWorkflowContext,
  missionInterveneParams,
  persistWorkflowContext,
  workflowTargetLabel,
} from '../workflow-context'
import { relativeTime as relativeTimeBase, formatDuration } from '../lib/format-time'
import { trimText } from '../lib/truncate'
import { toneClass } from '../lib/tone'
import { statusLabel } from '../lib/status-label'

export { formatDuration, trimText, toneClass, statusLabel }

export function relativeTime(iso?: string | null): string {
  return relativeTimeBase(iso, '방금')
}

export type EnrichedKeeperRow = {
  brief: DashboardMissionKeeperBrief
  keeper: Keeper | null
  currentWork: string
  recentInput: string | null
  recentOutput: string | null
  recentEvent: string | null
  recentTools: string[]
}

export type EnrichedAgentRow = {
  brief: DashboardMissionAgentBrief
  agent: Agent | null
  keeper: Keeper | null
  where: string
  withWhom: string[]
  currentWork: string
  how: string | null
  recentInput: string | null
  recentOutput: string | null
  recentEvent: string | null
  recentTools: string[]
}

export const selectedAttentionId = signal<string | null>(null)
export const selectedSessionId = signal<string | null>(null)

export function missionTargetTypeLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'namespace':
      return '프로젝트'
    case 'room':
      return '프로젝트'
    case 'session':
      return '세션'
    case 'operation':
      return '작전'
    case 'keeper':
      return '키퍼'
    case 'agent':
      return '에이전트'
    default:
      return value?.trim() || '대상'
  }
}

export function signalClassLabel(value?: string | null): string | null {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'metadata_gap':
      return '메타데이터 부족'
    case 'mixed':
      return '신호 혼재'
    case '':
      return null
    default:
      return value?.trim() || null
  }
}

export function actionModeLabel(action?: OperatorRecommendedAction | null): string {
  return action?.confirm_required ? '확인 후 실행' : '즉시 실행'
}

export function actionTargetLabel(action?: OperatorRecommendedAction | null): string {
  return workflowTargetLabel(
    action ? createMissionWorkflowContext(action, null, '상황판 추천 액션') : null,
  )
}

function navigateWithContext(
  _mode: 'intervene' | 'command',
  context = createMissionWorkflowContext(),
): void {
  persistWorkflowContext(context)
  navigate(
    'command',
    { section: 'operations', ...missionInterveneParams(context) },
  )
}

export function openIncidentIntervene(item: OperatorAttentionItem): void {
  navigateWithContext('intervene', createMissionWorkflowContext(null, item, '상황판 incident'))
}

export function openIncidentCommand(item: OperatorAttentionItem): void {
  navigateWithContext('command', createMissionWorkflowContext(null, item, '상황판 incident'))
}

export function openActionIntervene(
  action: OperatorRecommendedAction,
  incident?: OperatorAttentionItem | null,
  sourceLabel = '상황판 추천 액션',
): void {
  navigateWithContext('intervene', createMissionWorkflowContext(action, incident, sourceLabel))
}

export function openActionCommand(
  action: OperatorRecommendedAction,
  incident?: OperatorAttentionItem | null,
  sourceLabel = '상황판 추천 액션',
): void {
  navigateWithContext('command', createMissionWorkflowContext(action, incident, sourceLabel))
}

export function openSession(_mode: 'intervene' | 'command', sessionId: string): void {
  navigate('workspace', { section: 'session', session_id: sessionId, source: 'mission' })
}

export function attentionAsIncident(item: DashboardMissionAttentionQueueItem): OperatorAttentionItem {
  return {
    kind: item.kind,
    severity: item.severity,
    summary: item.summary,
    target_type: item.target_type,
    target_id: item.target_id ?? null,
    actor: null,
    evidence: item.evidence_preview,
  }
}

export function enrichedKeeperRow(brief: DashboardMissionKeeperBrief): EnrichedKeeperRow {
  const keeper =
    findKeeper(brief.name) ?? findKeeper(brief.agent_name)
  return {
    brief,
    keeper,
    currentWork:
      trimText(brief.current_work, 110)
      ?? trimText(keeper?.skill_primary, 110)
      ?? trimText(keeper?.last_proactive_reason, 110)
      ?? '명시된 키퍼 초점 없음',
    recentInput:
      trimText(keeper?.recent_input_preview, 120) ?? null,
    recentOutput:
      trimText(keeper?.recent_output_preview, 120)
      ?? trimText(keeper?.last_proactive_preview, 120)
      ?? null,
    recentEvent:
      trimText(keeper?.last_proactive_reason, 120)
      ?? null,
    recentTools: keeper?.recent_tool_names ?? [],
  }
}

export function sessionLookupById() {
  const mission = missionSnapshot.value
  if (!mission) return new Map<string, DashboardMissionSessionBrief>()
  return new Map(mission.sessions.map(item => [item.session_id, item]))
}

export function toggleAttention(id: string): void {
  selectedAttentionId.value = selectedAttentionId.value === id ? null : id
  selectedSessionId.value = null
}

export function toggleSession(id: string): void {
  selectedSessionId.value = selectedSessionId.value === id ? null : id
  selectedAttentionId.value = null
}

export function clearMissionSelection(): void {
  selectedAttentionId.value = null
  selectedSessionId.value = null
}

export function liveStateClass(status?: string | null, health?: string | null): string {
  const s = (status ?? health ?? '').trim().toLowerCase()
  if (s === 'offline' || s === 'inactive' || s === 'archived') return 'mission-state-offline'
  if (s === 'idle' || s === 'quiet' || s === 'stale' || s === 'paused' || s === 'blocked') return 'mission-state-idle'
  if (s === 'active' || s === 'running' || s === 'ok' || s === 'healthy') return 'mission-state-alive'
  return ''
}

/** Tailwind bg override for the status dot based on live state */
export function dotStateBg(stateClass: string): string {
  if (stateClass === 'mission-state-idle') return 'bg-[var(--warn)]'
  if (stateClass === 'mission-state-offline') return 'bg-[#555]'
  return ''
}

import { signal } from '@preact/signals'
import { navigate } from '../router'
import { missionSnapshot } from '../mission-store'
import { keepers } from '../store'
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
  missionCommandParams,
  missionInterveneParams,
  persistWorkflowContext,
  workflowTargetLabel,
} from '../workflow-context'
import { relativeTime as relativeTimeBase, formatDuration } from '../lib/format-time'
import { trimText } from '../lib/truncate'
import { toneClass } from '../lib/tone'

export { formatDuration, trimText, toneClass }

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

export function statusLabel(value?: string | null): string {
  const normalized = (value ?? '').trim().toLowerCase()
  switch (normalized) {
    case 'ok':
    case 'healthy':
    case 'green':
      return '안정'
    case 'active':
    case 'running':
      return '진행 중'
    case 'pending':
      return '대기 중'
    case 'paused':
      return '일시정지'
    case 'blocked':
      return '차단됨'
    case 'interrupted':
      return '중단됨'
    case 'warn':
    case 'watch':
      return '주의'
    case 'bad':
    case 'critical':
    case 'risk':
      return '위험'
    case 'degraded':
      return '저하'
    case 'offline':
      return '오프라인'
    case 'idle':
    case 'quiet':
      return '대기'
    case 'loading':
      return '불러오는 중'
    case 'error':
      return '오류'
    case 'unavailable':
      return '사용 불가'
    case 'stale':
      return '오래됨'
    case 'refreshing':
      return '갱신 중'
    case 'cached':
      return '캐시됨'
    case 'unknown':
    case '':
      return '확인 필요'
    default:
      return value?.trim() || '확인 필요'
  }
}

export function missionTargetTypeLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'room':
      return '방'
    case 'team_session':
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
  tab: 'intervene' | 'command',
  context = createMissionWorkflowContext(),
): void {
  persistWorkflowContext(context)
  navigate(tab, tab === 'intervene' ? missionInterveneParams(context) : missionCommandParams(context))
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

export function openSession(tab: 'intervene' | 'command', sessionId: string): void {
  const params: Record<string, string> = {
    source: 'mission',
    target_type: 'team_session',
    target_id: sessionId,
    focus_kind: 'team_session',
  }
  if (tab === 'command') params.surface = 'swarm'
  navigate(tab, params)
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
    keepers.value.find(item => item.name === brief.name || item.agent_name === brief.agent_name) ?? null
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
      ?? trimText(keeper?.diagnostic?.last_reply_preview, 120)
      ?? trimText(keeper?.last_proactive_preview, 120)
      ?? null,
    recentEvent:
      trimText(keeper?.last_proactive_reason, 120)
      ?? trimText(keeper?.diagnostic?.summary, 120)
      ?? null,
    recentTools: keeper?.recent_tool_names ?? [],
  }
}

export function sessionLookupById() {
  const mission = missionSnapshot.value
  if (!mission) return new Map<string, DashboardMissionSessionBrief>()
  const rows = mission.sessions.length > 0 ? mission.sessions : mission.session_briefs
  return new Map(rows.map(item => [item.session_id, item]))
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
  if (s === 'idle' || s === 'quiet' || s === 'stale') return 'mission-state-idle'
  if (s === 'active' || s === 'running' || s === 'ok' || s === 'healthy') return 'mission-state-alive'
  return ''
}

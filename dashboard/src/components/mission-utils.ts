import { signal } from '@preact/signals'
import { extractAgentInfo } from './common/agent-info'
import { navigate } from '../router'
import { missionSnapshot } from '../mission-store'
import { agents, keepers, messages, tasks } from '../store'
import type {
  Agent,
  DashboardMissionAgentBrief,
  DashboardMissionAttentionQueueItem,
  DashboardMissionKeeperBrief,
  DashboardMissionSessionBrief,
  Keeper,
  Message,
  OperatorAttentionItem,
  OperatorRecommendedAction,
  Task,
} from '../types'
import {
  createMissionWorkflowContext,
  missionCommandParams,
  missionInterveneParams,
  persistWorkflowContext,
  workflowTargetLabel,
} from '../workflow-context'

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

export type EnrichedKeeperRow = {
  brief: DashboardMissionKeeperBrief
  keeper: Keeper | null
  currentWork: string
  recentInput: string | null
  recentOutput: string | null
  recentEvent: string | null
  recentTools: string[]
}

export const selectedAttentionId = signal<string | null>(null)
export const selectedSessionId = signal<string | null>(null)

export function trimText(value: string | null | undefined, max = 120): string | null {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return null
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

export function toneClass(tone?: string | null): string {
  if (tone === 'bad' || tone === 'offline' || tone === 'critical' || tone === 'risk') return 'bad'
  if (tone === 'warn' || tone === 'pending' || tone === 'degraded' || tone === 'interrupted' || tone === 'watch') return 'warn'
  return 'ok'
}

export function relativeTime(iso?: string | null): string {
  if (!iso) return '방금'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}초 전`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}분 전`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}시간 전`
  return `${Math.round(deltaSec / 86400)}일 전`
}

export function formatDuration(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return '확인 필요'
  if (seconds < 60) return `${Math.round(seconds)}초`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분`
  if (seconds < 86400) return `${Math.round(seconds / 3600)}시간`
  return `${Math.round(seconds / 86400)}일`
}

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
      return '막힘'
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
      return '캐시'
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

function latestMessageFrom(agentName: string, rows: Message[]): Message | null {
  const key = agentName.trim().toLowerCase()
  return [...rows]
    .filter(item => (item.from ?? '').trim().toLowerCase() === key)
    .sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp))[0] ?? null
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function containsDirectMention(content: string, agentName: string): boolean {
  if (!agentName) return false
  const escaped = escapeRegex(agentName)
  const pattern = new RegExp(`(?:^|[^a-z0-9_])@${escaped}(?![a-z0-9_-])`, 'i')
  return pattern.test(content)
}

function latestMessageTo(agentName: string, rows: Message[]): Message | null {
  const key = agentName.trim().toLowerCase()
  return [...rows]
    .filter(item => {
      const from = (item.from ?? '').trim().toLowerCase()
      if (from === key) return false
      const content = (item.content ?? '').trim().toLowerCase()
      return containsDirectMention(content, key)
    })
    .sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp))[0] ?? null
}

function keeperForAgent(agentName: string): Keeper | null {
  return keepers.value.find(keeper =>
    keeper.agent_name === agentName || keeper.name === agentName,
  ) ?? null
}

function agentByName(name: string): Agent | null {
  return agents.value.find(agent => agent.name === name) ?? null
}

function taskLabel(taskId: string | null | undefined, taskList: Task[]): string | null {
  const current = trimText(taskId, 100)
  if (!current) return null
  const byId = taskList.find(task => task.id === current)
  if (byId) return `${byId.id} · ${trimText(byId.title, 92)}`
  const byTitle = taskList.find(task => task.title === current)
  if (byTitle) return `${byTitle.id} · ${trimText(byTitle.title, 92)}`
  return current
}

export function enrichedAgentRow(brief: DashboardMissionAgentBrief): EnrichedAgentRow {
  const agent = agentByName(brief.agent_name)
  const keeper = keeperForAgent(brief.agent_name)
  const latestOut = latestMessageFrom(brief.agent_name, messages.value)
  const latestIn = latestMessageTo(brief.agent_name, messages.value)
  const info = extractAgentInfo(brief.agent_name)
  const how =
    keeper?.skill_primary
    ?? (agent?.capabilities && agent.capabilities.length > 0 ? agent.capabilities.slice(0, 3).join(', ') : null)
    ?? info.model
    ?? agent?.agent_type
    ?? null

  return {
    brief,
    agent,
    keeper,
    where: brief.where ?? '방 정보 없음',
    withWhom: brief.with_whom,
    currentWork:
      brief.current_work
      ?? taskLabel(agent?.current_task ?? null, tasks.value)
      ?? '명시된 current task 없음',
    how,
    recentInput:
      trimText(brief.recent_input_preview, 120)
      ?? trimText(latestIn?.content, 120)
      ?? trimText(keeper?.recent_input_preview, 120)
      ?? null,
    recentOutput:
      trimText(brief.recent_output_preview, 120)
      ?? trimText(latestOut?.content, 120)
      ?? trimText(keeper?.recent_output_preview, 120)
      ?? trimText(keeper?.diagnostic?.last_reply_preview, 120)
      ?? null,
    recentEvent:
      trimText(brief.recent_event, 120)
      ?? trimText(keeper?.diagnostic?.summary, 120)
      ?? null,
    recentTools:
      brief.recent_tool_names.length > 0
        ? brief.recent_tool_names
        : keeper?.recent_tool_names ?? [],
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

export function memberPreview(name: string) {
  const agent = agentByName(name)
  const latestOut = latestMessageFrom(name, messages.value)
  const info = extractAgentInfo(name)
  return {
    name,
    model: info.model,
    nickname: info.nickname,
    currentTask: taskLabel(agent?.current_task ?? null, tasks.value) ?? 'agent snapshot 없음',
    output: trimText(latestOut?.content, 96),
  }
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

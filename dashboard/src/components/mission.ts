import { html } from 'htm/preact'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { extractAgentInfo, isKeeperAgent } from './common/agent-info'
import { navigate } from '../router'
import {
  missionBriefing,
  missionBriefingError,
  missionBriefingLoading,
  missionError,
  missionLoading,
  missionSnapshot,
  refreshMissionBriefing,
} from '../mission-store'
import { agentMotionMap, agents, keepers, messages, tasks } from '../store'
import { openAgentDetail } from './agent-detail'
import { openKeeperDetail } from './keeper-detail'
import type {
  Agent,
  Keeper,
  Message,
  OperatorAttentionItem,
  OperatorRecommendedAction,
  OperatorSessionSnapshot,
  Task,
} from '../types'
import {
  createMissionWorkflowContext,
  extractActionPayload,
  missionCommandParams,
  missionInterveneParams,
  persistWorkflowContext,
  summarizePayloadPreview,
  workflowActionLabel,
  workflowTargetLabel,
} from '../workflow-context'

type CrewRow = {
  session: OperatorSessionSnapshot
  goal: string
  room: string | null
  status: string
  memberNames: string[]
  startedAt: string | null
  stoppedAt: string | null
  elapsedSec: number | null
  lastEventAt: string | null
  lastEventSummary: string
  communicationMode: string | null
  broadcastCount: number
  portalCount: number
  activeCount: number
  requiredCount: number
  attentionSummary: string | null
}

type AgentActivityRow = {
  agent: Agent
  where: string
  withWhom: string[]
  activeSince: string | null
  currentWork: string
  how: string | null
  recentInput: string | null
  recentOutput: string | null
  recentEvent: string | null
  recentTools: string[]
}

type KeeperActivityRow = {
  keeper: Keeper
  activeSince: string | null
  currentWork: string
  recentInput: string | null
  recentOutput: string | null
  recentEvent: string | null
  recentTools: string[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => (typeof item === 'string' ? item.trim() : ''))
    .filter(Boolean)
}

function trimText(value: string | null | undefined, max = 120): string | null {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return null
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

function toneClass(tone?: string | null): string {
  if (tone === 'bad' || tone === 'offline' || tone === 'critical') return 'bad'
  if (tone === 'warn' || tone === 'pending' || tone === 'degraded' || tone === 'interrupted') return 'warn'
  return 'ok'
}

function relativeTime(iso?: string | null): string {
  if (!iso) return '방금'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}s 전`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}m 전`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}h 전`
  return `${Math.round(deltaSec / 86400)}d 전`
}

function formatDuration(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return 'n/a'
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  if (seconds < 86400) return `${Math.round(seconds / 3600)}h`
  return `${Math.round(seconds / 86400)}d`
}

function eventTimestamp(row: Record<string, unknown>): number {
  const unix = asNumber(row.ts)
  if (unix != null) return unix
  const iso = asString(row.ts_iso)
  if (!iso) return 0
  const parsed = Date.parse(iso)
  return Number.isNaN(parsed) ? 0 : parsed
}

function dedupe(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))]
}

function actionModeLabel(action?: OperatorRecommendedAction | null): string {
  return action?.confirm_required ? '확인 후 실행' : '즉시 실행'
}

function actionPayloadPreview(action?: OperatorRecommendedAction | null): string | null {
  return summarizePayloadPreview(extractActionPayload(action))
}

function actionTargetLabel(action?: OperatorRecommendedAction | null): string {
  return workflowTargetLabel(
    action
      ? createMissionWorkflowContext(action, null, '상황판 추천 액션')
      : null,
  )
}

function navigateWithContext(
  tab: 'intervene' | 'command',
  context = createMissionWorkflowContext(),
): void {
  persistWorkflowContext(context)
  navigate(tab, tab === 'intervene' ? missionInterveneParams(context) : missionCommandParams(context))
}

function openIncidentIntervene(item: OperatorAttentionItem): void {
  navigateWithContext('intervene', createMissionWorkflowContext(null, item, '상황판 incident'))
}

function openIncidentCommand(item: OperatorAttentionItem): void {
  navigateWithContext('command', createMissionWorkflowContext(null, item, '상황판 incident'))
}

function openActionIntervene(
  action: OperatorRecommendedAction,
  incident?: OperatorAttentionItem | null,
  sourceLabel = '상황판 추천 액션',
): void {
  navigateWithContext('intervene', createMissionWorkflowContext(action, incident, sourceLabel))
}

function openActionCommand(
  action: OperatorRecommendedAction,
  incident?: OperatorAttentionItem | null,
  sourceLabel = '상황판 추천 액션',
): void {
  navigateWithContext('command', createMissionWorkflowContext(action, incident, sourceLabel))
}

function openSession(tab: 'intervene' | 'command', sessionId: string): void {
  const params: Record<string, string> = {
    source: 'mission',
    target_type: 'team_session',
    target_id: sessionId,
    focus_kind: 'team_session',
  }
  if (tab === 'command') params.surface = 'swarm'
  navigate(tab, params)
}

function latestMessageFrom(agentName: string, rows: Message[]): Message | null {
  const key = agentName.trim().toLowerCase()
  return [...rows]
    .filter(item => (item.from ?? '').trim().toLowerCase() === key)
    .sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp))[0] ?? null
}

function latestMessageTo(agentName: string, rows: Message[]): Message | null {
  const key = agentName.trim().toLowerCase()
  return [...rows]
    .filter(item => {
      const from = (item.from ?? '').trim().toLowerCase()
      if (from === key) return false
      const content = (item.content ?? '').trim().toLowerCase()
      return content.includes(`@${key}`) || content.includes(key)
    })
    .sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp))[0] ?? null
}

function memberNamesForSession(session: OperatorSessionSnapshot): string[] {
  const rawSession = isRecord(session.session) ? session.session : {}
  const summary = isRecord(session.summary) ? session.summary : {}
  return dedupe([
    ...stringArray(rawSession.agent_names),
    ...stringArray(summary.active_agents),
    ...stringArray(summary.planned_participants),
  ]).filter(name => !isKeeperAgent(name))
}

function sessionGoal(session: OperatorSessionSnapshot): string {
  const rawSession = isRecord(session.session) ? session.session : {}
  return (
    asString(rawSession.goal)
    ?? asString(rawSession.session_id)
    ?? session.session_id
  )
}

function sessionRoom(session: OperatorSessionSnapshot): string | null {
  const rawSession = isRecord(session.session) ? session.session : {}
  return asString(rawSession.room_id)
}

function sessionStartedAt(session: OperatorSessionSnapshot): string | null {
  const rawSession = isRecord(session.session) ? session.session : {}
  return asString(rawSession.created_at_iso)
}

function sessionStoppedAt(session: OperatorSessionSnapshot): string | null {
  const rawSession = isRecord(session.session) ? session.session : {}
  return asString(rawSession.updated_at_iso)
}

function sessionCommunicationMode(session: OperatorSessionSnapshot): string | null {
  const metrics = isRecord(session.communication_metrics) ? session.communication_metrics : {}
  return asString(metrics.mode)
}

function sessionBroadcastCount(session: OperatorSessionSnapshot): number {
  const metrics = isRecord(session.communication_metrics) ? session.communication_metrics : {}
  return asNumber(metrics.broadcast_count) ?? 0
}

function sessionPortalCount(session: OperatorSessionSnapshot): number {
  const metrics = isRecord(session.communication_metrics) ? session.communication_metrics : {}
  return asNumber(metrics.portal_count) ?? 0
}

function sessionCoverage(session: OperatorSessionSnapshot): { active: number; required: number } {
  const health = isRecord(session.team_health) ? session.team_health : {}
  return {
    active: asNumber(health.active_agents_count) ?? 0,
    required: asNumber(health.required_agents) ?? 0,
  }
}

function sessionLastEvent(session: OperatorSessionSnapshot): { at: string | null; summary: string } {
  const recent = [...(session.recent_events ?? [])]
  const latest = recent
    .sort((a, b) => {
      return eventTimestamp(b) - eventTimestamp(a)
    })[0]
  if (!latest) {
    return {
      at: null,
      summary: '최근 session event가 없습니다.',
    }
  }
  const detail = isRecord(latest.detail) ? latest.detail : {}
  const eventType = asString(latest.event_type) ?? 'event'
  const actor = asString(detail.actor)
  const taskTitle = asString(detail.task_title) ?? asString(detail.title)
  const result = trimText(asString(detail.result), 120)
  const reason = trimText(asString(detail.reason), 120)
  const summary =
    taskTitle
      ? `${actor ? `${actor} · ` : ''}${taskTitle}`
      : result
        ?? reason
        ?? eventType.replace(/_/g, ' ')
  return {
    at: asString(latest.ts_iso),
    summary,
  }
}

function crewRowsFromMission(): CrewRow[] {
  const mission = missionSnapshot.value
  if (!mission) return []
  return mission.operator_targets.sessions
    .map(session => {
      const coverage = sessionCoverage(session)
      const lastEvent = sessionLastEvent(session)
      const topCard = mission.command_focus.session_cards.find(card => card.session_id === session.session_id)
      return {
        session,
        goal: sessionGoal(session),
        room: sessionRoom(session),
        status: session.status ?? 'unknown',
        memberNames: memberNamesForSession(session),
        startedAt: sessionStartedAt(session),
        stoppedAt: sessionStoppedAt(session),
        elapsedSec: session.elapsed_sec ?? null,
        lastEventAt: lastEvent.at,
        lastEventSummary: lastEvent.summary,
        communicationMode: sessionCommunicationMode(session),
        broadcastCount: sessionBroadcastCount(session),
        portalCount: sessionPortalCount(session),
        activeCount: coverage.active,
        requiredCount: coverage.required,
        attentionSummary: topCard?.top_attention?.summary ?? topCard?.top_recommendation?.reason ?? null,
      }
    })
    .sort((a, b) => {
      const aTs = Date.parse(a.lastEventAt ?? a.startedAt ?? '') || 0
      const bTs = Date.parse(b.lastEventAt ?? b.startedAt ?? '') || 0
      return bTs - aTs
    })
}

function keeperToolNames(keeper: Keeper): string[] {
  if (keeper.recent_tool_names && keeper.recent_tool_names.length > 0) return keeper.recent_tool_names
  const metrics = isRecord(keeper.metrics_window) ? keeper.metrics_window : {}
  const topTools = Array.isArray(metrics.top_tools) ? metrics.top_tools : []
  return topTools
    .map(item => (isRecord(item) ? asString(item.tool) : null))
    .filter((item): item is string => item !== null)
}

function keeperForAgent(agentName: string): Keeper | null {
  return keepers.value.find(keeper =>
    keeper.agent_name === agentName || keeper.name === agentName,
  ) ?? null
}

function taskLabel(agent: Agent, taskList: Task[]): string {
  const current = trimText(agent.current_task, 100)
  if (!current) return '명시된 current task 없음'
  const byId = taskList.find(task => task.id === current)
  if (byId) return `${byId.id} · ${trimText(byId.title, 92)}`
  const byTitle = taskList.find(task => task.title === current)
  if (byTitle) return `${byTitle.id} · ${trimText(byTitle.title, 92)}`
  return current
}

function agentRowsFromMission(crews: CrewRow[]): AgentActivityRow[] {
  const crewByMember = new Map<string, CrewRow>()
  for (const crew of crews) {
    for (const member of crew.memberNames) {
      if (!crewByMember.has(member)) crewByMember.set(member, crew)
    }
  }

  return [...agents.value]
    .map(agent => {
      const crew = crewByMember.get(agent.name)
      const keeper = keeperForAgent(agent.name)
      const latestOut = latestMessageFrom(agent.name, messages.value)
      const latestIn = latestMessageTo(agent.name, messages.value)
      const motion = agentMotionMap.value.get(agent.name.trim().toLowerCase())
      const peers = crew ? crew.memberNames.filter(name => name !== agent.name) : []
      const where = crew
        ? `${crew.goal}${crew.room ? ` · ${crew.room}` : ''}`
        : (missionSnapshot.value?.summary.current_room ?? 'room')
      const how =
        keeper?.skill_primary
        ?? (agent.capabilities && agent.capabilities.length > 0 ? agent.capabilities.slice(0, 3).join(', ') : null)
        ?? agent.agent_type
        ?? null
      const currentWork =
        taskLabel(agent, tasks.value)
      return {
        agent,
        where,
        withWhom: peers,
        activeSince: crew?.startedAt ?? agent.joined_at ?? agent.last_seen ?? null,
        currentWork,
        how,
        recentInput:
          trimText(latestIn?.content, 120)
          ?? trimText(keeper?.recent_input_preview, 120)
          ?? null,
        recentOutput:
          trimText(latestOut?.content, 120)
          ?? trimText(keeper?.recent_output_preview, 120)
          ?? trimText(keeper?.diagnostic?.last_reply_preview, 120)
          ?? null,
        recentEvent:
          trimText(motion?.lastActivityText, 120)
          ?? crew?.lastEventSummary
          ?? null,
        recentTools: keeper ? keeperToolNames(keeper) : [],
      }
    })
    .sort((a, b) => {
      const statusRank = (value: Agent['status']) =>
        value === 'busy' ? 4 : value === 'active' ? 3 : value === 'listening' ? 2 : value === 'idle' ? 1 : 0
      const statusDiff = statusRank(b.agent.status) - statusRank(a.agent.status)
      if (statusDiff !== 0) return statusDiff
      const aTs = Date.parse(a.agent.last_seen ?? a.activeSince ?? '') || 0
      const bTs = Date.parse(b.agent.last_seen ?? b.activeSince ?? '') || 0
      return bTs - aTs
    })
}

function keeperRowsFromMission(): KeeperActivityRow[] {
  return [...keepers.value]
    .map(keeper => ({
      keeper,
      activeSince: keeper.agent?.joined_at ?? keeper.created_at ?? keeper.last_heartbeat ?? null,
      currentWork:
        trimText(keeper.agent?.current_task, 110)
        ?? trimText(keeper.skill_primary, 110)
        ?? trimText(keeper.last_proactive_reason, 110)
        ?? '명시된 keeper focus 없음',
      recentInput:
        trimText(keeper.recent_input_preview, 120)
        ?? null,
      recentOutput:
        trimText(keeper.recent_output_preview, 120)
        ?? trimText(keeper.diagnostic?.last_reply_preview, 120)
        ?? trimText(keeper.last_proactive_preview, 120)
        ?? null,
      recentEvent:
        trimText(keeper.last_proactive_reason, 120)
        ?? trimText(keeper.diagnostic?.summary, 120)
        ?? null,
      recentTools: keeperToolNames(keeper),
    }))
    .sort((a, b) => {
      const aTs = Date.parse(a.keeper.last_heartbeat ?? a.activeSince ?? '') || 0
      const bTs = Date.parse(b.keeper.last_heartbeat ?? b.activeSince ?? '') || 0
      return bTs - aTs
    })
}

function MissionContextBar({
  cluster,
  project,
  room,
  generatedAt,
}: {
  cluster?: string
  project?: string
  room?: string | null
  generatedAt?: string
}) {
  return html`
    <div class="mission-context-bar">
      <div class="mission-context-item">
        <span>cluster</span>
        <strong>${cluster ?? '확인 없음'}</strong>
      </div>
      <div class="mission-context-item">
        <span>project</span>
        <strong>${project ?? '확인 없음'}</strong>
      </div>
      <div class="mission-context-item">
        <span>room</span>
        <strong>${room ?? 'default'}</strong>
      </div>
      <div class="mission-context-item">
        <span>generated</span>
        <strong>${generatedAt ? relativeTime(generatedAt) : 'fresh'}</strong>
      </div>
    </div>
  `
}

function SummaryStat({
  label,
  value,
  detail,
  tone,
}: {
  label: string
  value: string | number
  detail: string
  tone?: string | null
}) {
  return html`
    <article class="mission-stat-card ${toneClass(tone)}">
      <span class="mission-stat-label">${label}</span>
      <strong class="mission-stat-value">${value}</strong>
      <small class="mission-stat-detail">${detail}</small>
    </article>
  `
}

function MissionBriefingCard() {
  const briefing = missionBriefing.value
  const briefingTone = toneClass(briefing?.status ?? (missionBriefingError.value ? 'bad' : 'warn'))
  const showEmpty = !briefing || briefing.sections.length === 0
  const retryNeedsForce =
    briefing?.status === 'error'
    || (briefing?.status === 'unavailable' && !briefing?.cached)
  return html`
    <${Card} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>아래 해석은 LLM이 사실 스냅샷만 읽고 만든 요약입니다. raw thinking은 숨기고, 기준과 근거만 남깁니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${briefingTone}">
          ${briefing?.status ?? (missionBriefingError.value ? 'error' : 'loading')}
        </span>
        ${briefing?.model ? html`<span class="command-chip">${briefing.model}</span>` : null}
        ${briefing?.generated_at ? html`<span class="command-chip">${relativeTime(briefing.generated_at)}</span>` : null}
        ${briefing?.cached ? html`<span class="command-chip">cached</span>` : null}
        ${briefing?.stale ? html`<span class="command-chip warn">stale</span>` : null}
        ${briefing?.refreshing ? html`<span class="command-chip warn">refreshing</span>` : null}
      </div>

      ${missionBriefingError.value ? html`<div class="empty-state error">${missionBriefingError.value}</div>` : null}
      ${briefing?.error ? html`<div class="empty-state error">${briefing.error}</div>` : null}
      ${briefing?.summary ? html`<div class="mission-inline-note">${briefing.summary}</div>` : null}
      ${briefing?.last_error && !briefing.error
        ? html`<div class="mission-inline-note">최근 refresh 실패: ${briefing.last_error}</div>`
        : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="mission-briefing-grid">
              ${briefing.sections.map(section => html`
                <article class="mission-briefing-section ${toneClass(section.status)}">
                  <div class="mission-card-head">
                    <strong>${section.label}</strong>
                    <span class="command-chip ${toneClass(section.status)}">${section.status}</span>
                  </div>
                  <p>${section.summary}</p>
                  ${section.evidence.length > 0
                    ? html`
                        <div class="mission-briefing-evidence">
                          ${section.evidence.map(item => html`<span>${item}</span>`)}
                        </div>
                      `
                    : null}
                </article>
              `)}
            </div>
          `
        : (!missionBriefingLoading.value && !missionBriefingError.value && showEmpty
            ? html`
                <div class="empty-state">
                  ${briefing?.status === 'pending'
                    ? '최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.'
                    : '아직 판단 레이어를 불러오지 못했습니다.'}
                </div>
              `
            : null)}

      ${briefing?.criteria && briefing.criteria.length > 0
        ? html`
            <details class="mission-briefing-criteria">
              <summary>판단 기준 보기</summary>
              <div class="mission-briefing-evidence">
                ${briefing.criteria.map(item => html`<span>${item}</span>`)}
              </div>
            </details>
          `
        : null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => { void refreshMissionBriefing(retryNeedsForce) }} disabled=${missionBriefingLoading.value}>
          ${missionBriefingLoading.value ? '응답 기다리는 중…' : '판단 다시 읽기'}
        </button>
        <button class="control-btn ghost" onClick=${() => { void refreshMissionBriefing(true) }} disabled=${missionBriefingLoading.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `
}

function CrewCard({ row }: { row: CrewRow }) {
  const memberRows = row.memberNames.slice(0, 4).map(name => {
    const agent = agents.value.find(item => item.name === name)
    const output = latestMessageFrom(name, messages.value)
    const info = extractAgentInfo(name)
    return {
      name,
      model: info.model,
      nickname: info.nickname,
      currentTask: agent ? taskLabel(agent, tasks.value) : 'agent snapshot 없음',
      output: trimText(output?.content, 96),
    }
  })

  return html`
    <article class="mission-crew-card ${toneClass(row.status)}">
      <div class="mission-card-head">
        <div>
          <strong>${row.goal}</strong>
          <div class="mission-card-target">${row.session.session_id}${row.room ? ` · ${row.room}` : ''}</div>
        </div>
        <span class="command-chip ${toneClass(row.status)}">${row.status}</span>
      </div>

      <div class="mission-fact-grid">
        <div class="mission-fact-tile">
          <span>멤버</span>
          <strong>${row.memberNames.length}</strong>
          <small>${row.memberNames.slice(0, 3).join(', ') || 'n/a'}</small>
        </div>
        <div class="mission-fact-tile">
          <span>가동 시간</span>
          <strong>${formatDuration(row.elapsedSec)}</strong>
          <small>${row.startedAt ? `${relativeTime(row.startedAt)} 시작` : '시작 시각 없음'}</small>
        </div>
        <div class="mission-fact-tile">
          <span>커뮤니케이션</span>
          <strong>${row.broadcastCount + row.portalCount}</strong>
          <small>${row.communicationMode ?? 'mode n/a'} · broadcast ${row.broadcastCount} · portal ${row.portalCount}</small>
        </div>
        <div class="mission-fact-tile">
          <span>커버리지</span>
          <strong>${row.activeCount}/${row.requiredCount || row.activeCount || 1}</strong>
          <small>active / required</small>
        </div>
      </div>

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${row.lastEventSummary}</strong>
        <small>${row.lastEventAt ? relativeTime(row.lastEventAt) : '시각 없음'}</small>
      </div>

      ${memberRows.length > 0
        ? html`
            <div class="mission-member-stack">
              ${memberRows.map(member => html`
                <button class="mission-member-row" onClick=${() => openAgentDetail(member.name)}>
                  <strong>${member.model !== member.nickname ? html`<span class="model-badge">${member.model}</span> ` : ''}${member.nickname}</strong>
                  <span>${member.currentTask}</span>
                  <small>${member.output ?? '최근 출력 없음'}</small>
                </button>
              `)}
            </div>
          `
        : null}

      ${row.attentionSummary ? html`<div class="mission-inline-note">attention: ${row.attentionSummary}</div>` : null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => openSession('intervene', row.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${() => openSession('command', row.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `
}

function AgentCard({ row }: { row: AgentActivityRow }) {
  const toolPreview = row.recentTools.length > 0 ? row.recentTools.join(', ') : '도구 텔레메트리 없음'
  const who = row.withWhom.length > 0 ? row.withWhom.slice(0, 3).join(', ') : '단독 또는 room-level'

  return html`
    <button class="mission-activity-card ${toneClass(row.agent.status)}" onClick=${() => openAgentDetail(row.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${row.agent.emoji ?? ''}</span>
          <div>
            <strong>${row.agent.name}</strong>
            ${row.agent.koreanName ? html`<span>${row.agent.koreanName}</span>` : null}
          </div>
        </div>
        <span class="command-chip ${toneClass(row.agent.status)}">${row.agent.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>어디서 · ${row.where}</span>
        <span>누구와 · ${who}</span>
        <span>언제부터 · ${row.activeSince ? relativeTime(row.activeSince) : 'n/a'}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${row.currentWork}</strong>
        ${row.how ? html`<small>어떻게 · ${row.how}</small>` : null}
      </div>

      <div class="mission-io-stack">
        <div class="mission-io-item">
          <span>최근 input</span>
          <strong>${row.recentInput ?? '명시된 recent input 없음'}</strong>
        </div>
        <div class="mission-io-item">
          <span>최근 output</span>
          <strong>${row.recentOutput ?? '명시된 recent output 없음'}</strong>
        </div>
      </div>

      <div class="mission-activity-foot">
        <span>최근 도구 · ${toolPreview}</span>
        ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : null}
      </div>
    </button>
  `
}

function KeeperCard({ row }: { row: KeeperActivityRow }) {
  const continuity = [
    `gen ${row.keeper.generation ?? 0}`,
    `handoff ${row.keeper.handoff_count_total ?? 0}`,
    `compact ${row.keeper.compaction_count ?? 0}`,
    row.keeper.context_ratio != null ? `ctx ${Math.round(row.keeper.context_ratio * 100)}%` : null,
  ]
    .filter((value): value is string => value !== null)
    .join(' · ')

  return html`
    <button class="mission-activity-card ${toneClass(row.keeper.status)}" onClick=${() => openKeeperDetail(row.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${row.keeper.emoji ?? ''}</span>
          <div>
            <strong>${row.keeper.name}</strong>
            ${row.keeper.koreanName ? html`<span>${row.keeper.koreanName}</span>` : null}
          </div>
        </div>
        <span class="command-chip ${toneClass(row.keeper.status)}">${row.keeper.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>언제부터 · ${row.activeSince ? relativeTime(row.activeSince) : 'n/a'}</span>
        <span>최근 heartbeat · ${row.keeper.last_heartbeat ? relativeTime(row.keeper.last_heartbeat) : 'n/a'}</span>
        <span>${continuity}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${row.currentWork}</strong>
        ${row.keeper.skill_reason ? html`<small>판단 요약 · ${trimText(row.keeper.skill_reason, 120)}</small>` : null}
      </div>

      <div class="mission-io-stack">
        <div class="mission-io-item">
          <span>최근 input</span>
          <strong>${row.recentInput ?? '명시된 recent input 없음'}</strong>
        </div>
        <div class="mission-io-item">
          <span>최근 output</span>
          <strong>${row.recentOutput ?? '명시된 recent output 없음'}</strong>
        </div>
      </div>

      <div class="mission-activity-foot">
        <span>최근 도구 · ${row.recentTools.length > 0 ? row.recentTools.join(', ') : '도구 사용 없음'}</span>
        ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : null}
      </div>
    </button>
  `
}

function InternalIncidentCard({ item }: { item: OperatorAttentionItem }) {
  return html`
    <article class="mission-action-card ${toneClass(item.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${toneClass(item.severity)}">${item.kind}</span>
        <span class="mission-card-target">${item.target_type}${item.target_id ? ` · ${item.target_id}` : ''}</span>
      </div>
      <p>${item.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => openIncidentIntervene(item)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${() => openIncidentCommand(item)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `
}

function InternalActionCard({
  action,
  incident,
}: {
  action: OperatorRecommendedAction
  incident?: OperatorAttentionItem | null
}) {
  const payloadPreview = actionPayloadPreview(action)
  return html`
    <article class="mission-action-card ${toneClass(action.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${toneClass(action.severity)}">${workflowActionLabel(action.action_type)}</span>
        <span class="mission-card-target">${action.target_type}${action.target_id ? ` · ${action.target_id}` : ''}</span>
      </div>
      <p>${action.reason}</p>
      <div class="mission-action-detail">
        <span>${actionModeLabel(action)}</span>
        <span>${actionTargetLabel(action)}</span>
      </div>
      ${payloadPreview ? html`<div class="mission-action-preview">${payloadPreview}</div>` : null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => openActionIntervene(action, incident, '상황판 추천 액션')}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${() => openActionCommand(action, incident, '상황판 추천 액션')}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `
}

export function Mission() {
  const mission = missionSnapshot.value
  if (missionLoading.value && !mission) {
    return html`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`
  }
  if (missionError.value && !mission) {
    return html`<div class="empty-state error">${missionError.value}</div>`
  }
  if (!mission) {
    return html`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`
  }

  const crews = crewRowsFromMission()
  const agentRows = agentRowsFromMission(crews)
  const keeperRows = keeperRowsFromMission()
  const activeAgentsCount = agentRows.filter(row => ['active', 'busy', 'listening', 'idle'].includes(row.agent.status)).length
  const liveOutputs = agentRows.filter(row => row.recentOutput).length + keeperRows.filter(row => row.recentOutput).length
  const topIncident = mission.incidents[0] ?? null
  const topAction = mission.recommended_actions[0] ?? null

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>사람 운영자가 누가 어디서 누구와 무엇을 하고 있는지 바로 보는 관찰면입니다. 내부 메트릭은 아래가 아니라 Command로 내렸습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${toneClass(mission.summary.room_health)}">${mission.summary.room_health ?? 'ok'}</span>
          <span class="command-chip">${mission.summary.project ?? 'room'}${mission.summary.current_room ? ` · ${mission.summary.current_room}` : ''}</span>
          <span class="command-chip">${mission.generated_at ? relativeTime(mission.generated_at) : 'fresh'}</span>
        </div>
      </div>

      <${MissionContextBar}
        cluster=${mission.summary.cluster}
        project=${mission.summary.project}
        room=${mission.summary.current_room}
        generatedAt=${mission.generated_at}
      />

      <${MissionBriefingCard} />

      <div class="mission-stat-grid">
        <${SummaryStat} label="활성 흐름" value=${crews.length} detail="지금 보이는 crew / session" tone=${crews.length > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="응답 가능 에이전트" value=${activeAgentsCount} detail="지금 응답 가능한 actor 수" tone=${activeAgentsCount > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="Keeper 수" value=${keeperRows.length} detail="연속성 runtime / generation 관찰 대상" tone=${keeperRows.length > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="최근 output" value=${liveOutputs} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${liveOutputs > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="내부 incident" value=${mission.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${topIncident?.severity ?? 'ok'} />
        <${SummaryStat} label="추천 액션" value=${mission.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${topAction?.severity ?? 'ok'} />
      </div>

      <div class="mission-human-grid">
        <${Card} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${crews.length > 0
              ? crews.map(row => html`<${CrewCard} key=${row.session.session_id} row=${row} />`)
              : html`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${agentRows.length > 0
              ? agentRows.slice(0, 10).map(row => html`<${AgentCard} key=${row.agent.name} row=${row} />`)
              : html`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="Keeper 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>generation / compaction / handoff 를 거치는 장기 실행체</h3>
            <p>keeper 는 별도 continuity lane 으로 보고, raw thinking 대신 최근 입출력과 판단 요약만 노출합니다.</p>
          </div>
          <div class="mission-activity-list">
            ${keeperRows.length > 0
              ? keeperRows.slice(0, 8).map(row => html`<${KeeperCard} key=${row.keeper.name} row=${row} />`)
              : html`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${mission.incidents.slice(0, 2).map(item => html`<${InternalIncidentCard} key=${`${item.kind}:${item.target_id ?? 'room'}`} item=${item} />`)}
            ${mission.recommended_actions.slice(0, 2).map(action => html`<${InternalActionCard} key=${`${action.action_type}:${action.target_id ?? 'room'}`} action=${action} />`)}
            ${mission.incidents.length === 0 && mission.recommended_actions.length === 0
              ? html`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`
              : null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${() => navigate('execution')}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${() => navigate('command')}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `
}

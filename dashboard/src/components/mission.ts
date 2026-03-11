import { html } from 'htm/preact'
import { signal } from '@preact/signals'
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
import { agents, keepers, messages, tasks } from '../store'
import { openAgentDetail } from './agent-detail'
import { openKeeperDetail } from './keeper-detail'
import type {
  Agent,
  DashboardMissionAgentBrief,
  DashboardMissionAttentionQueueItem,
  DashboardMissionInternalSignal,
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
  workflowActionLabel,
  workflowTargetLabel,
} from '../workflow-context'

type EnrichedAgentRow = {
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

type EnrichedKeeperRow = {
  brief: DashboardMissionKeeperBrief
  keeper: Keeper | null
  currentWork: string
  recentInput: string | null
  recentOutput: string | null
  recentEvent: string | null
  recentTools: string[]
}

const selectedAttentionId = signal<string | null>(null)
const selectedSessionId = signal<string | null>(null)

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function trimText(value: string | null | undefined, max = 120): string | null {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return null
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

function toneClass(tone?: string | null): string {
  if (tone === 'bad' || tone === 'offline' || tone === 'critical' || tone === 'risk') return 'bad'
  if (tone === 'warn' || tone === 'pending' || tone === 'degraded' || tone === 'interrupted' || tone === 'watch') return 'warn'
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

function actionModeLabel(action?: OperatorRecommendedAction | null): string {
  return action?.confirm_required ? '확인 후 실행' : '즉시 실행'
}

function actionTargetLabel(action?: OperatorRecommendedAction | null): string {
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

function attentionAsIncident(item: DashboardMissionAttentionQueueItem): OperatorAttentionItem {
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
      const mention = (item.mention ?? '').trim().toLowerCase()
      if (mention === key) return true
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

function enrichedAgentRow(brief: DashboardMissionAgentBrief): EnrichedAgentRow {
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
    where: brief.where ?? 'room',
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

function enrichedKeeperRow(brief: DashboardMissionKeeperBrief): EnrichedKeeperRow {
  const keeper =
    keepers.value.find(item => item.name === brief.name || item.agent_name === brief.agent_name) ?? null
  return {
    brief,
    keeper,
    currentWork:
      trimText(brief.current_work, 110)
      ?? trimText(keeper?.skill_primary, 110)
      ?? trimText(keeper?.last_proactive_reason, 110)
      ?? '명시된 keeper focus 없음',
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

function sessionLookupById() {
  const mission = missionSnapshot.value
  if (!mission) return new Map<string, DashboardMissionSessionBrief>()
  return new Map(mission.session_briefs.map(item => [item.session_id, item]))
}

function memberPreview(name: string) {
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

function toggleAttention(id: string): void {
  selectedAttentionId.value = selectedAttentionId.value === id ? null : id
  selectedSessionId.value = null
}

function toggleSession(id: string): void {
  selectedSessionId.value = selectedSessionId.value === id ? null : id
}

function clearMissionSelection(): void {
  selectedAttentionId.value = null
  selectedSessionId.value = null
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
  const retryNeedsForce =
    briefing?.status === 'error'
    || (briefing?.status === 'unavailable' && !briefing?.cached)

  return html`
    <${Card} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${briefingTone}">
          ${briefing?.status ?? (missionBriefingError.value ? 'error' : 'loading')}
        </span>
        ${briefing?.model ? html`<span class="command-chip">${briefing.model}</span>` : null}
        ${briefing?.generated_at ? html`<span class="command-chip">${relativeTime(briefing.generated_at)}</span>` : null}
        ${briefing?.cached ? html`<span class="command-chip">cached</span>` : null}
        ${briefing?.stale ? html`<span class="command-chip warn">stale</span>` : null}
      </div>

      ${missionBriefingError.value ? html`<div class="empty-state error">${missionBriefingError.value}</div>` : null}
      ${briefing?.error ? html`<div class="empty-state error">${briefing.error}</div>` : null}
      ${briefing?.summary ? html`<div class="mission-inline-note">${briefing.summary}</div>` : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="mission-briefing-grid">
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="mission-briefing-section ${toneClass(section.status)}">
                  <div class="mission-card-head">
                    <strong>${section.label}</strong>
                    <span class="command-chip ${toneClass(section.status)}">${section.status}</span>
                  </div>
                  <p>${section.summary}</p>
                  ${section.evidence.length > 0
                    ? html`
                        <details class="mission-card-disclosure compact">
                          <summary>근거 보기</summary>
                          <div class="mission-pill-row">
                            ${section.evidence.map(item => html`<span class="mission-pill">${item}</span>`)}
                          </div>
                        </details>
                      `
                    : null}
                </article>
              `)}
            </div>
          `
        : (!missionBriefingLoading.value && !missionBriefingError.value
            ? html`<div class="empty-state">판단 레이어 결과가 아직 없습니다.</div>`
            : null)}

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

function AttentionCard({
  item,
  selected,
  sessionLookup,
}: {
  item: DashboardMissionAttentionQueueItem
  selected: boolean
  sessionLookup: Map<string, DashboardMissionSessionBrief>
}) {
  const incident = attentionAsIncident(item)
  const linkedSessions = item.related_session_ids
    .map(id => sessionLookup.get(id))
    .filter((row): row is DashboardMissionSessionBrief => row != null)
  const action = item.top_action ?? null

  return html`
    <article class="mission-attention-card ${toneClass(action?.severity ?? item.severity)} ${selected ? 'is-selected' : ''}">
      <button class="mission-card-select" onClick=${() => toggleAttention(item.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${item.summary}</strong>
            <div class="mission-card-target">${item.kind}${item.target_id ? ` · ${item.target_id}` : ''}</div>
          </div>
          <span class="command-chip ${toneClass(action?.severity ?? item.severity)}">${action ? actionModeLabel(action) : item.severity}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>영향 session</span>
            <strong>${item.related_session_ids.length}</strong>
            <small>${item.related_session_ids.slice(0, 2).join(', ') || '없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>영향 agent</span>
            <strong>${item.related_agent_names.length}</strong>
            <small>${item.related_agent_names.slice(0, 3).join(', ') || '없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 신호</span>
            <strong>${item.last_seen_at ? relativeTime(item.last_seen_at) : 'n/a'}</strong>
            <small>${item.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${action ? workflowActionLabel(action.action_type) : '판단 필요'}</strong>
            <small>${action ? actionTargetLabel(action) : '추천 액션 없음'}</small>
          </div>
        </div>
      </button>

      ${action ? html`<div class="mission-inline-note">${action.reason}</div>` : null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${linkedSessions.length > 0
          ? html`
              <div class="mission-link-list">
                ${linkedSessions.slice(0, 4).map(session => html`
                  <button class="mission-link-row" onClick=${() => toggleSession(session.session_id)}>
                    <strong>${session.goal}</strong>
                    <span>${session.status ?? 'unknown'} · ${session.last_event_summary ?? '최근 사건 없음'}</span>
                  </button>
                `)}
              </div>
            `
          : html`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${item.related_agent_names.length > 0
          ? html`
              <div class="mission-pill-row">
                ${item.related_agent_names.slice(0, 8).map(name => html`
                  <button class="mission-pill action" onClick=${() => openAgentDetail(name)}>${name}</button>
                `)}
              </div>
            `
          : null}

        ${item.evidence_preview.length > 0
          ? html`
              <details class="mission-card-disclosure compact">
                <summary>evidence preview</summary>
                <div class="mission-evidence-list">
                  ${item.evidence_preview.map(text => html`<span>${text}</span>`)}
                </div>
              </details>
            `
          : null}
      </details>

      <div class="mission-card-actions">
        ${action
          ? html`
              <button class="control-btn ghost" onClick=${() => openActionIntervene(action, incident, 'Mission attention')}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${() => openActionCommand(action, incident, 'Mission attention')}>
                원인 보기
              </button>
            `
          : html`
              <button class="control-btn ghost" onClick=${() => openIncidentIntervene(incident)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${() => openIncidentCommand(incident)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `
}

function SessionBriefCard({
  brief,
  selected,
}: {
  brief: DashboardMissionSessionBrief
  selected: boolean
}) {
  const members = brief.member_names.slice(0, 6).map(memberPreview)
  const action = brief.top_recommendation ?? null
  const incident = brief.top_attention ?? null

  return html`
    <article class="mission-crew-card ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)} ${selected ? 'is-selected' : ''}">
      <button class="mission-card-select" onClick=${() => toggleSession(brief.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${brief.goal}</strong>
            <div class="mission-card-target">${brief.session_id}${brief.room ? ` · ${brief.room}` : ''}</div>
          </div>
          <span class="command-chip ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)}">${brief.status ?? 'unknown'}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${brief.member_names.length}</strong>
            <small>${brief.member_names.slice(0, 3).join(', ') || 'n/a'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${formatDuration(brief.elapsed_sec)}</strong>
            <small>${brief.started_at ? `${relativeTime(brief.started_at)} 시작` : '시작 시각 없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커뮤니케이션</span>
            <strong>${brief.communication_summary ? '요약됨' : 'n/a'}</strong>
            <small>${brief.communication_summary ?? '요약 없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커버리지</span>
            <strong>${brief.active_count ?? 0}/${brief.required_count || 1}</strong>
            <small>active / required</small>
          </div>
        </div>
      </button>

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${brief.last_event_summary ?? '최근 session event가 없습니다.'}</strong>
        <small>${brief.last_event_at ? relativeTime(brief.last_event_at) : '시각 없음'}</small>
      </div>

      ${brief.top_attention ? html`<div class="mission-inline-note">attention: ${brief.top_attention.summary}</div>` : null}

      <details class="mission-card-disclosure">
        <summary>session detail</summary>
        ${members.length > 0
          ? html`
              <div class="mission-pill-row">
                ${members.map(member => html`
                  <button class="mission-pill action" onClick=${() => openAgentDetail(member.name)}>
                    ${member.model !== member.nickname ? `${member.model} · ` : ''}${member.nickname}
                  </button>
                `)}
              </div>
            `
          : null}

        ${members.length > 0
          ? html`
              <details class="mission-card-disclosure compact">
                <summary>member output preview</summary>
                <div class="mission-link-list">
                  ${members.map(member => html`
                    <button class="mission-link-row" onClick=${() => openAgentDetail(member.name)}>
                      <strong>${member.nickname}</strong>
                      <span>${member.currentTask}</span>
                      <small>${member.output ?? '최근 출력 없음'}</small>
                    </button>
                  `)}
                </div>
              </details>
            `
          : null}
      </details>

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => openSession('intervene', brief.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${() => openSession('command', brief.session_id)}>세션 원인 보기</button>
        ${action
          ? html`<button class="control-btn ghost" onClick=${() => openActionIntervene(action, incident, 'Mission session brief')}>추천 액션 열기</button>`
          : null}
      </div>
    </article>
  `
}

function AgentBriefCard({ row }: { row: EnrichedAgentRow }) {
  const info = extractAgentInfo(row.brief.agent_name)
  const who = row.withWhom.length > 0 ? row.withWhom.slice(0, 3).join(', ') : '단독 또는 room-level'
  return html`
    <article class="mission-activity-card ${toneClass(row.brief.status ?? row.agent?.status)}">
      <button class="mission-card-select" onClick=${() => openAgentDetail(row.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${row.agent?.emoji ?? row.keeper?.emoji ?? ''}</span>
            <div>
              <strong>${row.brief.agent_name}</strong>
              <span>${info.model !== info.nickname ? `${info.model} · ` : ''}${info.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${toneClass(row.brief.status ?? row.agent?.status)}">${row.brief.status ?? row.agent?.status ?? 'unknown'}</span>
        </div>

        <div class="mission-activity-meta">
          <span>어디서 · ${row.where}</span>
          <span>누구와 · ${who}</span>
          <span>attention · ${row.brief.related_attention_count}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.how ? html`<small>어떻게 · ${row.how}</small>` : null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>recent trace</summary>
        <div class="mission-activity-foot">
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : html`<span>최근 사건 요약 없음</span>`}
          <span>관련 session · ${row.brief.related_session_id ?? '없음'}</span>
        </div>

        <details class="mission-card-disclosure compact">
          <summary>input / output / tools</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 input</span>
              <strong>${row.recentInput ?? '표시 가능한 recent input 없음'}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 output</span>
              <strong>${row.recentOutput ?? '표시 가능한 recent output 없음'}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${row.recentTools.length > 0 ? row.recentTools.join(', ') : '도구 텔레메트리 없음'}</span>
          </div>
        </details>
      </details>
    </article>
  `
}

function KeeperBriefCard({ row }: { row: EnrichedKeeperRow }) {
  const continuity = [
    `gen ${row.brief.generation ?? row.keeper?.generation ?? 0}`,
    row.brief.context_ratio != null
      ? `ctx ${Math.round(row.brief.context_ratio * 100)}%`
      : (row.keeper?.context_ratio != null ? `ctx ${Math.round(row.keeper.context_ratio * 100)}%` : null),
    row.brief.last_turn_ago_s != null ? `last turn ${Math.round(row.brief.last_turn_ago_s)}s` : null,
  ]
    .filter((value): value is string => value !== null)
    .join(' · ')

  return html`
    <article class="mission-activity-card ${toneClass(row.brief.status ?? row.keeper?.status)}">
      <button class="mission-card-select" onClick=${() => { if (row.keeper) openKeeperDetail(row.keeper) }}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${row.keeper?.emoji ?? ''}</span>
            <div>
              <strong>${row.brief.name}</strong>
              ${row.keeper?.koreanName ? html`<span>${row.keeper.koreanName}</span>` : null}
            </div>
          </div>
          <span class="command-chip ${toneClass(row.brief.status ?? row.keeper?.status)}">${row.brief.status ?? row.keeper?.status ?? 'unknown'}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${row.keeper?.last_heartbeat ? relativeTime(row.keeper.last_heartbeat) : 'n/a'}</span>
          <span>${continuity || 'continuity 정보 없음'}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.keeper?.skill_reason ? html`<small>판단 요약 · ${trimText(row.keeper.skill_reason, 120)}</small>` : null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${row.brief.agent_name ?? row.keeper?.agent_name ?? 'n/a'}</span>
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>input / output / tools</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 input</span>
              <strong>${row.recentInput ?? '표시 가능한 recent input 없음'}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 output</span>
              <strong>${row.recentOutput ?? '표시 가능한 recent output 없음'}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${row.recentTools.length > 0 ? row.recentTools.join(', ') : '도구 사용 없음'}</span>
          </div>
        </details>
      </details>
    </article>
  `
}

function InternalSignalCard({ item }: { item: DashboardMissionInternalSignal }) {
  const action = item.action ?? null
  const attention = item.attention ?? null
  return html`
    <article class="mission-action-card ${toneClass(item.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${toneClass(item.severity)}">
          ${item.signal_type === 'action' && action ? workflowActionLabel(action.action_type) : attention?.kind ?? 'signal'}
        </span>
        <span class="mission-card-target">${item.target_type}${item.target_id ? ` · ${item.target_id}` : ''}</span>
      </div>
      <p>${item.summary}</p>
      ${action ? html`<div class="mission-action-preview">${action.reason}</div>` : null}
      <div class="mission-card-actions">
        ${action
          ? html`
              <button class="control-btn ghost" onClick=${() => openActionIntervene(action, attention, 'Mission internal signal')}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${() => openActionCommand(action, attention, 'Mission internal signal')}>이 이슈의 원인 보기</button>
            `
          : attention
            ? html`
                <button class="control-btn ghost" onClick=${() => openIncidentIntervene(attention)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${() => openIncidentCommand(attention)}>이 이슈의 원인 보기</button>
              `
            : null}
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

  if (selectedAttentionId.value && !mission.attention_queue.some(item => item.id === selectedAttentionId.value)) {
    selectedAttentionId.value = null
  }
  if (selectedSessionId.value && !mission.session_briefs.some(item => item.session_id === selectedSessionId.value)) {
    selectedSessionId.value = null
  }

  const activeAttention =
    mission.attention_queue.find(item => item.id === selectedAttentionId.value) ?? null
  const activeSessionId = selectedSessionId.value
  const sessionLookup = sessionLookupById()
  const activeSessionSet = activeAttention ? new Set(activeAttention.related_session_ids) : null
  const activeAgentSet = activeAttention ? new Set(activeAttention.related_agent_names) : null

  const sessionRows = (activeSessionSet
    ? mission.session_briefs.filter(item => activeSessionSet.has(item.session_id))
    : mission.session_briefs
  ).slice(0, activeAttention ? 8 : 6)

  const agentRows = mission.agent_briefs
    .filter(item => !isKeeperAgent(item.agent_name))
    .filter(item => {
      if (activeSessionId) return item.related_session_id === activeSessionId
      if (activeAgentSet && activeSessionSet) {
        return activeAgentSet.has(item.agent_name) || (item.related_session_id ? activeSessionSet.has(item.related_session_id) : false)
      }
      return true
    })
    .slice(0, activeSessionId || activeAttention ? 10 : 8)
    .map(enrichedAgentRow)

  const keeperRows = mission.keeper_briefs.slice(0, 6).map(enrichedKeeperRow)
  const attentionQueueCount = mission.attention_queue.length
  const attentionQueue = mission.attention_queue.slice(0, 6)
  const internalSignals = mission.internal_signals.slice(0, 3)
  const liveOutputs =
    agentRows.filter(row => row.recentOutput).length + keeperRows.filter(row => row.recentOutput).length

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
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
        <${SummaryStat} label="주의 큐" value=${attentionQueueCount} detail="개입 판단이 필요한 issue" tone=${attentionQueue[0]?.severity ?? 'ok'} />
        <${SummaryStat} label="영향 session" value=${sessionRows.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${sessionRows[0]?.top_attention?.severity ?? sessionRows[0]?.health ?? 'ok'} />
        <${SummaryStat} label="영향 agent" value=${agentRows.length} detail="선택된 흐름에 연결된 actor" tone=${agentRows[0]?.brief.status ?? 'ok'} />
        <${SummaryStat} label="Keeper watch" value=${keeperRows.length} detail="continuity lane 관찰 대상" tone=${keeperRows[0]?.brief.status ?? 'ok'} />
        <${SummaryStat} label="최근 output" value=${liveOutputs} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${liveOutputs > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="내부 신호" value=${internalSignals.length} detail="room/system 진단은 하단 보조 lane" tone=${internalSignals[0]?.severity ?? 'ok'} />
      </div>

      ${(activeAttention || activeSessionId)
        ? html`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${activeAttention ? activeAttention.summary : 'session 선택'}${activeSessionId ? ` · ${activeSessionId}` : ''}</span>
              <button class="control-btn ghost" onClick=${clearMissionSelection}>선택 해제</button>
            </div>
          `
        : null}

      <${Card} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${attentionQueue.length > 0
            ? attentionQueue.map(item => html`<${AttentionCard} key=${item.id} item=${item} selected=${selectedAttentionId.value === item.id} sessionLookup=${sessionLookup} />`)
            : html`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${Card} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${sessionRows.length > 0
              ? sessionRows.map(row => html`<${SessionBriefCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)
              : html`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${agentRows.length > 0
              ? agentRows.map(row => html`<${AgentBriefCard} key=${row.brief.agent_name} row=${row} />`)
              : html`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>continuity lane</h3>
            <p>keeper는 별도 lane으로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${keeperRows.length > 0
              ? keeperRows.map(row => html`<${KeeperBriefCard} key=${row.brief.name} row=${row} />`)
              : html`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${internalSignals.length > 0
              ? internalSignals.map(item => html`<${InternalSignalCard} key=${item.id} item=${item} />`)
              : html`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
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

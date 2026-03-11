import { html } from 'htm/preact'
import { Card } from './common/card'
import { extractAgentInfo } from './common/agent-info'
import { openAgentDetail } from './agent-detail'
import { openKeeperDetail } from './keeper-detail'
import {
  missionBriefing,
  missionBriefingError,
  missionBriefingLoading,
  refreshMissionBriefing,
} from '../mission-store'
import { workflowActionLabel } from '../workflow-context'
import type {
  DashboardMissionAttentionQueueItem,
  DashboardMissionInternalSignal,
  DashboardMissionSessionBrief,
} from '../types'
import {
  type EnrichedAgentRow,
  type EnrichedKeeperRow,
  toneClass,
  relativeTime,
  formatDuration,
  trimText,
  actionModeLabel,
  actionTargetLabel,
  toggleAttention,
  toggleSession,
  openIncidentIntervene,
  openIncidentCommand,
  openActionIntervene,
  openActionCommand,
  openSession,
  attentionAsIncident,
  memberPreview,
} from './mission-utils'

export function MissionContextBar({
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

export function SummaryStat({
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

export function MissionBriefingCard() {
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
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="mission-briefing-section ${toneClass(section.status)}">
                  <div class="mission-card-head">
                    <strong>${section.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${toneClass(section.status)}">${section.status}</span>
                      ${section.signal_class === 'metadata_gap'
                        ? html`<span class="command-chip">metadata gap</span>`
                        : section.signal_class === 'mixed'
                          ? html`<span class="command-chip warn">mixed</span>`
                          : null}
                      ${section.evidence_quality ? html`<span class="command-chip">${section.evidence_quality}</span>` : null}
                    </div>
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
        : (!missionBriefingLoading.value && !missionBriefingError.value && showEmpty
            ? html`
                <div class="empty-state">
                  ${briefing?.status === 'pending'
                    ? '최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.'
                    : '판단 레이어 결과가 아직 없습니다.'}
                </div>
              `
            : null)}

      ${briefing && briefing.metadata_gaps.length > 0
        ? html`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>Observability Gaps (${briefing.metadata_gap_count ?? briefing.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${briefing.metadata_gaps.map(item => html`
                  <article class="mission-briefing-gap ${item.severity === 'watch' ? 'warn' : ''}">
                    <div class="mission-card-head">
                      <strong>${item.scope_type}${item.scope_id ? ` · ${item.scope_id}` : ''}</strong>
                      <span class="command-chip ${item.severity === 'watch' ? 'warn' : ''}">${item.severity}</span>
                    </div>
                    <p>${item.summary}</p>
                  </article>
                `)}
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

export function AttentionCard({
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

export function SessionBriefCard({
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

export function AgentBriefCard({ row }: { row: EnrichedAgentRow }) {
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

export function KeeperBriefCard({ row }: { row: EnrichedKeeperRow }) {
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

export function InternalSignalCard({ item }: { item: DashboardMissionInternalSignal }) {
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

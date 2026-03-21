import { html } from 'htm/preact'
import { openAgentDetail } from './agent-detail'
import { workflowActionLabel } from '../workflow-context'
import type {
  DashboardMissionAttentionQueueItem,
  DashboardMissionSessionBrief,
} from '../types'
import {
  actionModeLabel,
  actionTargetLabel,
  attentionAsIncident,
  missionTargetTypeLabel,
  openActionCommand,
  openActionIntervene,
  openIncidentCommand,
  openIncidentIntervene,
  relativeTime,
  statusLabel,
  toggleAttention,
  toggleSession,
  toneClass,
} from './mission-utils'

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
            <div class="mission-card-target">${missionTargetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</div>
          </div>
          <span class="command-chip ${toneClass(action?.severity ?? item.severity)}">${action ? actionModeLabel(action) : item.severity}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>영향 세션</span>
            <strong>${item.related_session_ids.length}</strong>
            <small>${item.related_session_ids.slice(0, 2).join(', ') || '없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>영향 에이전트</span>
            <strong>${item.related_agent_names.length}</strong>
            <small>${item.related_agent_names.slice(0, 3).join(', ') || '없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 신호</span>
            <strong>${item.last_seen_at ? relativeTime(item.last_seen_at) : '기록 없음'}</strong>
            <small>${missionTargetTypeLabel(item.target_type)}</small>
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
                    <span>${statusLabel(session.status)} · ${session.last_event_summary ?? '최근 사건 없음'}</span>
                  </button>
                `)}
              </div>
            `
          : html`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

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
                <summary>근거 미리보기</summary>
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
              <button class="control-btn ghost" onClick=${() => openActionIntervene(action, incident, '상황판 주의 신호')}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${() => openActionCommand(action, incident, '상황판 주의 신호')}>
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

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
    <article class="mission-attention-card p-3.5 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(180deg,var(--white-6),var(--white-3))] grid gap-3 ${toneClass(action?.severity ?? item.severity)} ${selected ? 'is-selected' : ''}">
      <button class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${() => toggleAttention(item.id)}>
        <div class="flex justify-between gap-2 items-start flex-wrap">
          <div>
            <strong>${item.summary}</strong>
            <div class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-sm)]">${missionTargetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</div>
          </div>
          <span class="cmd-chip rounded-full ${toneClass(action?.severity ?? item.severity)}">${action ? actionModeLabel(action) : item.severity}</span>
        </div>

        <div class="grid grid-cols-2 gap-2.5">
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span>영향 세션</span>
            <strong>${item.related_session_ids.length}</strong>
            <small>${item.related_session_ids.slice(0, 2).join(', ') || '없음'}</small>
          </div>
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span>영향 에이전트</span>
            <strong>${item.related_agent_names.length}</strong>
            <small>${item.related_agent_names.slice(0, 3).join(', ') || '없음'}</small>
          </div>
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span>최근 신호</span>
            <strong>${item.last_seen_at ? relativeTime(item.last_seen_at) : '기록 없음'}</strong>
            <small>${missionTargetTypeLabel(item.target_type)}</small>
          </div>
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span>다음 액션</span>
            <strong>${action ? workflowActionLabel(action.action_type) : '판단 필요'}</strong>
            <small>${action ? actionTargetLabel(action) : '추천 액션 없음'}</small>
          </div>
        </div>
      </button>

      ${action ? html`<div class="grid gap-1">${action.reason}</div>` : null}

      <details class="pt-1 border-t border-[var(--white-6)]">
        <summary>연결된 흐름 보기</summary>
        ${linkedSessions.length > 0
          ? html`
              <div class="flex flex-col gap-2 mt-2.5">
                ${linkedSessions.slice(0, 4).map(session => html`
                  <button class="w-full py-2.5 px-3 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-1 text-left text-inherit cursor-pointer" onClick=${() => toggleSession(session.session_id)}>
                    <strong>${session.goal}</strong>
                    <span>${statusLabel(session.status)} · ${session.last_event_summary ?? '최근 사건 없음'}</span>
                  </button>
                `)}
              </div>
            `
          : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">직접 연결된 세션이 아직 없습니다.</div>`}

        ${item.related_agent_names.length > 0
          ? html`
              <div class="flex gap-2 flex-wrap mt-2.5">
                ${item.related_agent_names.slice(0, 8).map(name => html`
                  <button class="px-2.5 py-1.5 rounded-full border border-[var(--white-8)] bg-[var(--white-4)] text-[rgba(255,255,255,0.76)] text-[length:var(--fs-sm)] leading-[1.35] cursor-pointer" onClick=${() => openAgentDetail(name)}>${name}</button>
                `)}
              </div>
            `
          : null}

        ${item.evidence_preview.length > 0
          ? html`
              <details class="pt-1 border-t border-[var(--white-6)] mt-2">
                <summary>근거 미리보기</summary>
                <div class="grid gap-2 mt-2.5">
                  ${item.evidence_preview.map(text => html`<span>${text}</span>`)}
                </div>
              </details>
            `
          : null}
      </details>

      <div class="flex gap-2 flex-wrap mt-2.5">
        ${action
          ? html`
              <button class="control-btn rounded-lg ghost" onClick=${() => openActionIntervene(action, incident, '상황판 주의 신호')}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn rounded-lg ghost" onClick=${() => openActionCommand(action, incident, '상황판 주의 신호')}>
                원인 보기
              </button>
            `
          : html`
              <button class="control-btn rounded-lg ghost" onClick=${() => openIncidentIntervene(incident)}>이 이슈로 개입 열기</button>
              <button class="control-btn rounded-lg ghost" onClick=${() => openIncidentCommand(incident)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `
}

import { html } from 'htm/preact'
import { EmptyState } from './common/empty-state'
import { StatCell } from './common/stat-cell'
import { TagBadge } from './common/tag-badge'
import { ListItem } from './common/list-item'
import { ActionBar, ActionBtn } from './common/action-bar'
import { StatusChip } from './common/status-chip'
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
    <article class="mission-attention-card p-4 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(180deg,var(--white-6),var(--white-3))] grid gap-3 ${toneClass(action?.severity ?? item.severity)} ${selected ? 'is-selected' : ''}">
      <button class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${() => toggleAttention(item.id)}>
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <strong>${item.summary}</strong>
            <div class="text-[var(--text-muted)] text-[13px] mt-1">${missionTargetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</div>
          </div>
          <${StatusChip} label=${action ? actionModeLabel(action) : item.severity} tone=${toneClass(action?.severity ?? item.severity)} />
        </div>

        <div class="grid grid-cols-2 gap-3">
          <${StatCell} label="영향 세션" value=${item.related_session_ids.length} detail=${item.related_session_ids.slice(0, 2).join(', ') || '없음'} />
          <${StatCell} label="영향 에이전트" value=${item.related_agent_names.length} detail=${item.related_agent_names.slice(0, 3).join(', ') || '없음'} />
          <${StatCell} label="최근 신호" value=${item.last_seen_at ? relativeTime(item.last_seen_at) : '기록 없음'} detail=${missionTargetTypeLabel(item.target_type)} />
          <${StatCell} label="다음 액션" value=${action ? workflowActionLabel(action.action_type) : '판단 필요'} detail=${action ? actionTargetLabel(action) : '추천 액션 없음'} />
        </div>
      </button>

      ${action ? html`<div class="grid gap-1.5 px-1">${action.reason}</div>` : null}

      <details class="pt-2 border-t border-[var(--white-6)]">
        <summary>연결된 흐름 보기</summary>
        ${linkedSessions.length > 0
          ? html`
              <div class="flex flex-col gap-3 mt-3">
                ${linkedSessions.slice(0, 4).map(session => html`
                  <${ListItem}
                    title=${session.goal}
                    subtitle=${html`${statusLabel(session.status)} · ${session.last_event_summary ?? '최근 사건 없음'}`}
                    onClick=${() => toggleSession(session.session_id)}
                  />
                `)}
              </div>
            `
          : html`<${EmptyState} message="직접 연결된 세션이 아직 없습니다." compact />`}

        ${item.related_agent_names.length > 0
          ? html`
              <div class="flex gap-3 flex-wrap mt-3">
                ${item.related_agent_names.slice(0, 8).map(name => html`
                  <${TagBadge} onClick=${() => openAgentDetail(name)}>${name}<//>
                `)}
              </div>
            `
          : null}

        ${item.evidence_preview.length > 0
          ? html`
              <details class="pt-2 border-t border-[var(--white-6)] mt-3">
                <summary>근거 미리보기</summary>
                <div class="grid gap-3 mt-3">
                  ${item.evidence_preview.map(text => html`<span>${text}</span>`)}
                </div>
              </details>
            `
          : null}
      </details>

      <${ActionBar}>
        ${action
          ? html`
              <${ActionBtn} label="이 액션으로 개입 열기" onClick=${() => openActionIntervene(action, incident, '상황판 주의 신호')} />
              <${ActionBtn} label="원인 보기" onClick=${() => openActionCommand(action, incident, '상황판 주의 신호')} />
            `
          : html`
              <${ActionBtn} label="이 이슈로 개입 열기" onClick=${() => openIncidentIntervene(incident)} />
              <${ActionBtn} label="이 이슈의 원인 보기" onClick=${() => openIncidentCommand(incident)} />
            `}
      <//>
    </article>
  `
}

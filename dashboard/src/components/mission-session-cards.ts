import { html } from 'htm/preact'
import { Card } from './common/card'
import { openAgentDetail } from './agent-detail'
import type {
  DashboardMissionSessionCard,
  DashboardMissionSessionDetailResponse,
} from '../types'
import {
  toneClass,
  relativeTime,
  formatDuration,
  statusLabel,
  toggleSession,
  openActionIntervene,
  openSession,
  liveStateClass,
  dotStateBg,
} from './mission-utils'

export function SessionBriefCard({
  brief,
  selected,
}: {
  brief: DashboardMissionSessionCard
  selected: boolean
}) {
  const members = brief.member_previews.slice(0, 4)
  const action = brief.top_recommendation ?? null
  const incident = brief.top_attention ?? null
  const liveCount = brief.active_count ?? 0
  const seenCount = brief.seen_count ?? liveCount
  const plannedCount = brief.planned_count ?? brief.member_names.length

  return html`
    <article class="mission-crew-card ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)} ${liveStateClass(brief.status, brief.health)} ${selected ? 'is-selected' : ''}">
      <button class="mission-card-select" onClick=${() => toggleSession(brief.session_id)}>
        <div class="mission-card-head">
          <div>
            <div style="display:flex;align-items:center;gap:8px">
              <div class="mission-status-dot ${liveStateClass(brief.status, brief.health)} ${dotStateBg(liveStateClass(brief.status, brief.health))}"></div>
              <strong>${brief.goal}</strong>
            </div>
            <div class="mission-card-target">${brief.session_id}${brief.room ? ` · ${brief.room}` : ''}</div>
          </div>
          <span class="command-chip ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)}">${statusLabel(brief.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${brief.member_names.length}</strong>
            <small>${brief.member_names.slice(0, 3).join(', ') || '없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${formatDuration(brief.elapsed_sec)}</strong>
            <small>${brief.started_at ? `${relativeTime(brief.started_at)} 시작` : '시작 시각 없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${brief.last_event_at ? relativeTime(brief.last_event_at) : '기록 없음'}</strong>
            <small>${brief.communication_summary ?? '요약 없음'}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${liveCount}/${brief.required_count || 1}</strong>
            <small>live · seen ${seenCount} · planned ${plannedCount}</small>
          </div>
        </div>
      </button>

      ${brief.blocker_summary ? html`<div class="grid gap-1">막힘 · ${brief.blocker_summary}</div>` : null}
      ${brief.counts_basis ? html`<div class="grid gap-1">관측 기준 · ${brief.counts_basis}</div>` : null}

      <div class="grid gap-1">
        <span>최근 사건</span>
        <strong>${brief.last_event_summary ?? '최근 세션 이벤트가 없습니다.'}</strong>
        <small>${brief.last_event_at ? relativeTime(brief.last_event_at) : '시각 없음'}</small>
      </div>

      ${brief.operation_badges.length > 0
        ? html`
            <div class="mission-pill-row">
              ${brief.operation_badges.slice(0, 3).map(operation => html`
                <span class="mission-pill">
                  ${operation.operation_id} · ${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}
                </span>
              `)}
            </div>
          `
        : null}

      ${members.length > 0
        ? html`
            <div class="mission-member-preview-grid">
              ${members.map(member => html`
                <button class="mission-member-preview" onClick=${() => openAgentDetail(member.agent_name)}>
                  <strong>${member.agent_name}</strong>
                  <span>
                    ${member.current_work ?? '현재 작업 없음'}
                    ${member.is_live === false ? ' · archived' : member.is_live === true ? ' · live' : ''}
                  </span>
                  <small>${member.recent_output_preview ?? member.recent_input_preview ?? '최근 입출력 없음'}</small>
                </button>
              `)}
            </div>
          `
        : null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => openSession('intervene', brief.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${() => openSession('command', brief.session_id)}>세션 원인 보기</button>
        ${action
          ? html`<button class="control-btn ghost" onClick=${() => openActionIntervene(action, incident, '상황판 세션 요약')}>추천 액션 열기</button>`
          : null}
      </div>
    </article>
  `
}

export function SessionDetailCard({
  detail,
  loading,
  error,
}: {
  detail: DashboardMissionSessionDetailResponse | null
  loading: boolean
  error: string | null
}) {
  if (loading && !detail) {
    return html`
      <${Card} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `
  }

  if (error && !detail) {
    return html`
      <${Card} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${error}</div>
      <//>
    `
  }

  if (!detail?.session) {
    return null
  }

  const session = detail.session
  return html`
    <${Card} title="세션 상세" class="mission-list-card">
      <div class="mission-section-head">
        <h3>${session.goal}</h3>
        <p>${session.session_id}${session.room ? ` · ${session.room}` : ''}</p>
      </div>

      ${error ? html`<div class="grid gap-1">${error}</div>` : null}

      <div class="mission-detail-grid">
        <div class="grid gap-2.5">
          <div class="mission-card-head">
            <strong>타임라인</strong>
            <span class="command-chip">${detail.timeline.length}</span>
          </div>
          <div class="mission-timeline-list">
            ${detail.timeline.length > 0
              ? detail.timeline.map(item => html`
                  <article class="mission-timeline-row">
                    <div class="mission-card-head">
                      <strong>${item.summary}</strong>
                      <span>${item.timestamp ? relativeTime(item.timestamp) : '시각 없음'}</span>
                    </div>
                    <small>${item.actor ? `${item.actor} · ` : ''}${item.event_type ?? '이벤트'}</small>
                  </article>
                `)
              : html`<div class="empty-state">표시할 세션 이벤트가 없습니다.</div>`}
          </div>
        </div>

        <div class="grid gap-2.5">
          <div class="mission-card-head">
            <strong>참여자</strong>
            <span class="command-chip">${detail.participants.length}</span>
          </div>
          <div class="mission-activity-list compact">
            ${detail.participants.length > 0
              ? detail.participants.map(participant => html`
                  <button class="mission-member-preview" onClick=${() => openAgentDetail(participant.agent_name)}>
                    <strong>${participant.agent_name}</strong>
                    <span>${participant.current_work ?? '현재 작업 없음'}</span>
                    <small>
                      ${participant.recent_output_preview ?? participant.recent_input_preview ?? '최근 입출력 없음'}
                      ${participant.last_activity_at ? ` · ${relativeTime(participant.last_activity_at)}` : ''}
                    </small>
                  </button>
                `)
              : html`<div class="empty-state">세션 참여자 미리보기가 없습니다.</div>`}
          </div>
        </div>
      </div>

      <div class="mission-detail-grid">
        <div class="grid gap-2.5">
          <div class="mission-card-head">
            <strong>연결된 작전</strong>
            <span class="command-chip">${detail.operations.length}</span>
          </div>
          <div class="mission-link-list">
            ${detail.operations.length > 0
              ? detail.operations.map(operation => html`
                  <button class="mission-link-row" onClick=${() => openSession('command', session.session_id)}>
                    <strong>${operation.operation_id}</strong>
                    <span>${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}</span>
                    <small>${operation.detachment_status ?? operation.objective ?? '분견대 정보 없음'}</small>
                  </button>
                `)
              : html`<div class="empty-state">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="grid gap-2.5">
          <div class="mission-card-head">
            <strong>연속성 관찰</strong>
            <span class="command-chip">${detail.keepers.length}</span>
          </div>
          <div class="mission-link-list">
            ${detail.keepers.length > 0
              ? detail.keepers.map(keeper => html`
                  <div class="mission-link-row static">
                    <strong>${keeper.name}</strong>
                    <span>${statusLabel(keeper.status)}${keeper.generation != null ? ` · 세대 ${keeper.generation}` : ''}</span>
                    <small>${keeper.current_work ?? '현재 작업 정보 없음'}</small>
                  </div>
                `)
              : html`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `
}

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
    <article class="mission-crew-card p-3.5 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(180deg,var(--white-5),var(--white-3))] grid gap-3 ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)} ${liveStateClass(brief.status, brief.health)} ${selected ? 'is-selected' : ''}">
      <button class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${() => toggleSession(brief.session_id)}>
        <div class="flex justify-between gap-2 items-start flex-wrap">
          <div>
            <div style="display:flex;align-items:center;gap:8px">
              <div class="mission-status-dot ${liveStateClass(brief.status, brief.health)} ${dotStateBg(liveStateClass(brief.status, brief.health))}"></div>
              <strong>${brief.goal}</strong>
            </div>
            <div class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-sm)]">${brief.session_id}${brief.room ? ` · ${brief.room}` : ''}</div>
          </div>
          <span class="command-chip rounded-full ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)}">${statusLabel(brief.status)}</span>
        </div>

        <div class="grid grid-cols-2 gap-2.5">
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">멤버</span>
            <strong class="text-[var(--text-strong)] text-lg">${brief.member_names.length}</strong>
            <small class="grid gap-1">${brief.member_names.slice(0, 3).join(', ') || '없음'}</small>
          </div>
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">가동 시간</span>
            <strong class="text-[var(--text-strong)] text-lg">${formatDuration(brief.elapsed_sec)}</strong>
            <small class="grid gap-1">${brief.started_at ? `${relativeTime(brief.started_at)} 시작` : '시작 시각 없음'}</small>
          </div>
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">최근 흐름</span>
            <strong class="text-[var(--text-strong)] text-lg">${brief.last_event_at ? relativeTime(brief.last_event_at) : '기록 없음'}</strong>
            <small class="grid gap-1">${brief.communication_summary ?? '요약 없음'}</small>
          </div>
          <div class="p-3 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1">
            <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">충원 상태</span>
            <strong class="text-[var(--text-strong)] text-lg">${liveCount}/${brief.required_count || 1}</strong>
            <small class="grid gap-1">live · seen ${seenCount} · planned ${plannedCount}</small>
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
            <div class="flex gap-2 flex-wrap mt-2.5">
              ${brief.operation_badges.slice(0, 3).map(operation => html`
                <span class="px-2.5 py-1.5 rounded-full border border-[var(--white-8)] bg-[var(--white-4)] text-[rgba(255,255,255,0.76)] text-[length:var(--fs-sm)] leading-[1.35]">
                  ${operation.operation_id} · ${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}
                </span>
              `)}
            </div>
          `
        : null}

      ${members.length > 0
        ? html`
            <div class="grid grid-cols-2 gap-2.5">
              ${members.map(member => html`
                <button class="w-full p-3 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-1 text-left text-inherit" onClick=${() => openAgentDetail(member.agent_name)}>
                  <strong class="text-[var(--text-strong)]">${member.agent_name}</strong>
                  <span class="text-[rgba(255,255,255,0.72)] leading-[1.45]">
                    ${member.current_work ?? '현재 작업 없음'}
                    ${member.is_live === false ? ' · archived' : member.is_live === true ? ' · live' : ''}
                  </span>
                  <small class="text-[rgba(255,255,255,0.72)] leading-[1.45]">${member.recent_output_preview ?? member.recent_input_preview ?? '최근 입출력 없음'}</small>
                </button>
              `)}
            </div>
          `
        : null}

      <div class="flex gap-2 flex-wrap mt-2.5">
        <button class="control-btn rounded-lg ghost" onClick=${() => openSession('intervene', brief.session_id)}>세션 개입 열기</button>
        <button class="control-btn rounded-lg ghost" onClick=${() => openSession('command', brief.session_id)}>세션 원인 보기</button>
        ${action
          ? html`<button class="control-btn rounded-lg ghost" onClick=${() => openActionIntervene(action, incident, '상황판 세션 요약')}>추천 액션 열기</button>`
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
      <${Card} title="세션 상세" class="mission-list-card rounded-xl">
        <div class="text-center border border-dashed border-[var(--card-border)] rounded-xl py-12 px-4 text-[color:var(--text-muted)]">세션 상세 불러오는 중...</div>
      <//>
    `
  }

  if (error && !detail) {
    return html`
      <${Card} title="세션 상세" class="mission-list-card rounded-xl">
        <div class="empty-state error text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">${error}</div>
      <//>
    `
  }

  if (!detail?.session) {
    return null
  }

  const session = detail.session
  return html`
    <${Card} title="세션 상세" class="mission-list-card rounded-xl">
      <div class="grid gap-1 mb-3">
        <h3 class="m-0 text-[var(--text-strong)] text-lg">${session.goal}</h3>
        <p class="m-0 text-[rgba(255,255,255,0.68)] leading-normal">${session.session_id}${session.room ? ` · ${session.room}` : ''}</p>
      </div>

      ${error ? html`<div class="grid gap-1">${error}</div>` : null}

      <div class="grid grid-cols-2 gap-4 mt-3">
        <div class="grid gap-2.5">
          <div class="flex justify-between gap-2 items-start flex-wrap">
            <strong>타임라인</strong>
            <span class="command-chip rounded-full">${detail.timeline.length}</span>
          </div>
          <div class="flex flex-col gap-2.5">
            ${detail.timeline.length > 0
              ? detail.timeline.map(item => html`
                  <article class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-6)] grid gap-1">
                    <div class="flex justify-between gap-2 items-start flex-wrap">
                      <strong>${item.summary}</strong>
                      <span>${item.timestamp ? relativeTime(item.timestamp) : '시각 없음'}</span>
                    </div>
                    <small class="text-[rgba(255,255,255,0.68)] leading-[1.45]">${item.actor ? `${item.actor} · ` : ''}${item.event_type ?? '이벤트'}</small>
                  </article>
                `)
              : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">표시할 세션 이벤트가 없습니다.</div>`}
          </div>
        </div>

        <div class="grid gap-2.5">
          <div class="flex justify-between gap-2 items-start flex-wrap">
            <strong>참여자</strong>
            <span class="command-chip rounded-full">${detail.participants.length}</span>
          </div>
          <div class="flex flex-col gap-3 compact">
            ${detail.participants.length > 0
              ? detail.participants.map(participant => html`
                  <button class="w-full p-3 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-1 text-left text-inherit" onClick=${() => openAgentDetail(participant.agent_name)}>
                    <strong class="text-[var(--text-strong)]">${participant.agent_name}</strong>
                    <span class="text-[rgba(255,255,255,0.72)] leading-[1.45]">${participant.current_work ?? '현재 작업 없음'}</span>
                    <small class="text-[rgba(255,255,255,0.72)] leading-[1.45]">
                      ${participant.recent_output_preview ?? participant.recent_input_preview ?? '최근 입출력 없음'}
                      ${participant.last_activity_at ? ` · ${relativeTime(participant.last_activity_at)}` : ''}
                    </small>
                  </button>
                `)
              : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">세션 참여자 미리보기가 없습니다.</div>`}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-4 mt-3">
        <div class="grid gap-2.5">
          <div class="flex justify-between gap-2 items-start flex-wrap">
            <strong>연결된 작전</strong>
            <span class="command-chip rounded-full">${detail.operations.length}</span>
          </div>
          <div class="flex flex-col gap-2 mt-2.5">
            ${detail.operations.length > 0
              ? detail.operations.map(operation => html`
                  <button class="w-full py-2.5 px-3 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-1 text-left text-inherit cursor-pointer" onClick=${() => openSession('command', session.session_id)}>
                    <strong class="text-[var(--text-strong)]">${operation.operation_id}</strong>
                    <span class="text-[rgba(255,255,255,0.7)] leading-[1.45]">${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}</span>
                    <small class="text-[rgba(255,255,255,0.7)] leading-[1.45]">${operation.detachment_status ?? operation.objective ?? '분견대 정보 없음'}</small>
                  </button>
                `)
              : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="grid gap-2.5">
          <div class="flex justify-between gap-2 items-start flex-wrap">
            <strong>연속성 관찰</strong>
            <span class="command-chip rounded-full">${detail.keepers.length}</span>
          </div>
          <div class="flex flex-col gap-2 mt-2.5">
            ${detail.keepers.length > 0
              ? detail.keepers.map(keeper => html`
                  <div class="w-full py-2.5 px-3 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-1 text-left text-inherit cursor-default">
                    <strong class="text-[var(--text-strong)]">${keeper.name}</strong>
                    <span class="text-[rgba(255,255,255,0.7)] leading-[1.45]">${statusLabel(keeper.status)}${keeper.generation != null ? ` · 세대 ${keeper.generation}` : ''}</span>
                    <small class="text-[rgba(255,255,255,0.7)] leading-[1.45]">${keeper.current_work ?? '현재 작업 정보 없음'}</small>
                  </div>
                `)
              : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `
}

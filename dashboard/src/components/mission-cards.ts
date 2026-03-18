import { html } from 'htm/preact'
import { Card } from './common/card'
import { extractAgentInfo } from './common/agent-info'
import { linkedRecentToolsEmptyState, observedToolsEmptyState, toolAuditStateLabel } from './common/tool-audit'
import { ProvenanceStrip } from './common/provenance-strip'
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
  DashboardMissionSessionCard,
  DashboardMissionSessionDetailResponse,
} from '../types'
import {
  type EnrichedAgentRow,
  type EnrichedKeeperRow,
  toneClass,
  relativeTime,
  formatDuration,
  statusLabel,
  missionTargetTypeLabel,
  signalClassLabel,
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
  liveStateClass,
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
        <span>프로젝트</span>
        <strong>${project ?? '확인 없음'}</strong>
      </div>
      <div class="mission-context-item">
        <span>방</span>
        <strong>${room ?? '기본 방'}</strong>
      </div>
      <div class="mission-context-item">
        <span>갱신 시각</span>
        <strong>${generatedAt ? relativeTime(generatedAt) : '기록 없음'}</strong>
      </div>
      ${cluster && cluster !== 'unknown'
        ? html`
            <div class="mission-context-item">
              <span>배포 메타</span>
              <strong>${cluster}</strong>
            </div>
          `
        : null}
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
    <${Card} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <${ProvenanceStrip}
          items=${[
            { kind: 'narrative' },
            { kind: 'fallback', label: 'fallback on failure' },
          ]}
        />
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${briefingTone}">
          ${statusLabel(briefing?.status ?? (missionBriefingError.value ? 'error' : 'loading'))}
        </span>
        ${briefing?.model ? html`<span class="command-chip">${briefing.model}</span>` : null}
        ${briefing?.generated_at ? html`<span class="command-chip">${relativeTime(briefing.generated_at)}</span>` : null}
        ${briefing?.cached ? html`<span class="command-chip">캐시</span>` : null}
        ${briefing?.stale ? html`<span class="command-chip warn">오래됨</span>` : null}
        ${briefing?.refreshing ? html`<span class="command-chip warn">갱신 중</span>` : null}
      </div>

      ${missionBriefingError.value ? html`<div class="empty-state error">${missionBriefingError.value}</div>` : null}
      ${briefing?.error ? html`<div class="empty-state error">${briefing.error}</div>` : null}
      ${briefing?.summary ? html`<div class="mission-inline-note">${briefing.summary}</div>` : null}
      ${briefing?.last_error && !briefing.error
        ? html`<div class="mission-inline-note">최근 갱신 실패: ${briefing.last_error}</div>`
        : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="mission-briefing-grid">
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="mission-briefing-section ${toneClass(section.status)}">
                  <div class="mission-card-head">
                    <strong>${section.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${toneClass(section.status)}">${statusLabel(section.status)}</span>
                      ${signalClassLabel(section.signal_class)
                        ? html`<span class="command-chip ${section.signal_class === 'mixed' ? 'warn' : ''}">${signalClassLabel(section.signal_class)}</span>`
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
                    : '판단 결과가 아직 없습니다.'}
                </div>
              `
            : null)}

      ${briefing && briefing.metadata_gaps.length > 0
        ? html`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>관측 공백 (${briefing.metadata_gap_count ?? briefing.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${briefing.metadata_gaps.map(item => html`
                  <article class="mission-briefing-gap ${item.severity === 'watch' ? 'warn' : ''}">
                    <div class="mission-card-head">
                      <strong>${missionTargetTypeLabel(item.scope_type)}${item.scope_id ? ` · ${item.scope_id}` : ''}</strong>
                      <span class="command-chip ${item.severity === 'watch' ? 'warn' : ''}">${statusLabel(item.severity)}</span>
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
              <div class="mission-status-dot ${liveStateClass(brief.status, brief.health)}"></div>
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

      ${brief.blocker_summary ? html`<div class="mission-inline-note">막힘 · ${brief.blocker_summary}</div>` : null}
      ${brief.counts_basis ? html`<div class="mission-inline-note">관측 기준 · ${brief.counts_basis}</div>` : null}

      <div class="mission-crew-event">
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
        <button class="control-btn ghost" onClick=${() => openSession('control', brief.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${() => openSession('lab', brief.session_id)}>세션 원인 보기</button>
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
    <${Card} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
      <div class="mission-section-head">
        <h3>${session.goal}</h3>
        <p>${session.session_id}${session.room ? ` · ${session.room}` : ''}</p>
      </div>

      ${error ? html`<div class="mission-inline-note">${error}</div>` : null}

      <div class="mission-detail-grid">
        <div class="mission-detail-column">
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

        <div class="mission-detail-column">
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
        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연결된 작전</strong>
            <span class="command-chip">${detail.operations.length}</span>
          </div>
          <div class="mission-link-list">
            ${detail.operations.length > 0
              ? detail.operations.map(operation => html`
                  <button class="mission-link-row" onClick=${() => openSession('lab', session.session_id)}>
                    <strong>${operation.operation_id}</strong>
                    <span>${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}</span>
                    <small>${operation.detachment_status ?? operation.objective ?? '분견대 정보 없음'}</small>
                  </button>
                `)
              : html`<div class="empty-state">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
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

export function AgentBriefCard({ row }: { row: EnrichedAgentRow }) {
  const info = extractAgentInfo(row.brief.agent_name)
  const who = row.withWhom.length > 0 ? row.withWhom.slice(0, 3).join(', ') : '단독 또는 방 단위'
  const recentToolsLabel =
    row.recentTools.length > 0
      ? row.recentTools.join(', ')
      : toolAuditStateLabel(observedToolsEmptyState(row.keeper, row.brief.tool_audit_source))
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
          <span class="command-chip ${toneClass(row.brief.status ?? row.agent?.status)}">${statusLabel(row.brief.status ?? row.agent?.status)}</span>
        </div>

        <div class="mission-activity-meta">
          <span>어디서 · ${row.where}</span>
          <span>누구와 · ${who}</span>
          <span>주의 신호 · ${row.brief.related_attention_count}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.how ? html`<small>어떻게 · ${row.how}</small>` : null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>최근 흐름</summary>
        <div class="mission-activity-foot">
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : html`<span>최근 사건 요약 없음</span>`}
          <span>관련 세션 · ${row.brief.related_session_id ?? '없음'}</span>
        </div>

        <details class="mission-card-disclosure compact">
          <summary>입력 · 응답 · 도구</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 입력</span>
              <strong>${row.recentInput ?? '표시 가능한 최근 입력이 없습니다'}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 응답</span>
              <strong>${row.recentOutput ?? '표시 가능한 최근 응답이 없습니다'}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${recentToolsLabel}</span>
          </div>
        </details>
      </details>
    </article>
  `
}

export function KeeperBriefCard({ row }: { row: EnrichedKeeperRow }) {
  const continuity = [
    `세대 ${row.brief.generation ?? row.keeper?.generation ?? 0}`,
    row.brief.context_ratio != null
      ? `컨텍스트 ${Math.round(row.brief.context_ratio * 100)}%`
      : (row.keeper?.context_ratio != null ? `컨텍스트 ${Math.round(row.keeper.context_ratio * 100)}%` : null),
    row.brief.last_turn_ago_s != null ? `최근 턴 ${Math.round(row.brief.last_turn_ago_s)}초 전` : null,
  ]
    .filter((value): value is string => value !== null)
    .join(' · ')
  const recentToolsLabel =
    row.recentTools.length > 0
      ? row.recentTools.join(', ')
      : toolAuditStateLabel(linkedRecentToolsEmptyState(row.keeper))

  return html`
    <article class="mission-activity-card ${toneClass(row.brief.status ?? row.keeper?.status)} ${liveStateClass(row.brief.status, row.keeper?.status)}">
      <button class="mission-card-select" onClick=${() => { if (row.keeper) openKeeperDetail(row.keeper) }}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <div class="mission-status-dot ${liveStateClass(row.brief.status, row.keeper?.status)}"></div>
            <span class="agent-emoji">${row.keeper?.emoji ?? ''}</span>
            <div>
              <strong>${row.brief.name}</strong>
              ${row.keeper?.koreanName ? html`<span>${row.keeper.koreanName}</span>` : null}
            </div>
          </div>
          <span class="command-chip ${toneClass(row.brief.status ?? row.keeper?.status)}">${statusLabel(row.brief.status ?? row.keeper?.status)}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${row.keeper?.last_heartbeat ? relativeTime(row.keeper.last_heartbeat) : '기록 없음'}</span>
          <span>${continuity || '연속성 정보 없음'}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.keeper?.skill_reason ? html`<small>판단 요약 · ${trimText(row.keeper.skill_reason, 120)}</small>` : null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${row.brief.agent_name ?? row.keeper?.agent_name ?? '기록 없음'}</span>
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>입력 · 응답 · 도구</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 입력</span>
              <strong>${row.recentInput ?? '표시 가능한 최근 입력이 없습니다'}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 응답</span>
              <strong>${row.recentOutput ?? '표시 가능한 최근 응답이 없습니다'}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${recentToolsLabel}</span>
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
          ${item.signal_type === 'action' && action ? workflowActionLabel(action.action_type) : attention?.kind ?? '내부 신호'}
        </span>
        <span class="mission-card-target">${missionTargetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
      </div>
      <p>${item.summary}</p>
      ${action ? html`<div class="mission-action-preview">${action.reason}</div>` : null}
      <div class="mission-card-actions">
        ${action
          ? html`
              <button class="control-btn ghost" onClick=${() => openActionIntervene(action, attention, '상황판 내부 신호')}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${() => openActionCommand(action, attention, '상황판 내부 신호')}>이 이슈의 원인 보기</button>
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

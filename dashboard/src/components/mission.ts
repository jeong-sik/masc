import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { navigate } from '../router'
import {
  missionError,
  missionSessionDetail,
  missionSessionDetailError,
  missionSessionDetailLoading,
  missionLoading,
  missionSnapshot,
  refreshMissionSessionDetail,
} from '../mission-store'
import {
  selectedAttentionId,
  selectedSessionId,
  sessionLookupById,
  enrichedKeeperRow,
  clearMissionSelection,
  toneClass,
  relativeTime,
  statusLabel,
} from './mission-utils'
import {
  MissionContextBar,
  SummaryStat,
  AttentionCard,
  SessionBriefCard,
  SessionDetailCard,
  KeeperBriefCard,
  InternalSignalCard,
} from './mission-cards'
import { ProvenanceStrip } from './common/provenance-strip'

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

  const sessionRows = mission.sessions
  const activeSelectedAttentionId =
    selectedAttentionId.value && mission.attention_queue.some(item => item.id === selectedAttentionId.value)
      ? selectedAttentionId.value
      : null
  const activeSelectedSessionId =
    selectedSessionId.value && sessionRows.some(item => item.session_id === selectedSessionId.value)
      ? selectedSessionId.value
      : null

  useEffect(() => {
    if (selectedAttentionId.value !== activeSelectedAttentionId) {
      selectedAttentionId.value = activeSelectedAttentionId
    }
    if (selectedSessionId.value !== activeSelectedSessionId) {
      selectedSessionId.value = activeSelectedSessionId
    }
  }, [activeSelectedAttentionId, activeSelectedSessionId])

  const activeAttention = mission.attention_queue.find(item => item.id === activeSelectedAttentionId) ?? null
  const attentionSessionId =
    activeAttention?.related_session_ids.find(id => sessionRows.some(item => item.session_id === id)) ?? null
  const activeSessionId = activeSelectedSessionId ?? attentionSessionId ?? sessionRows[0]?.session_id ?? null
  const sessionLookup = sessionLookupById()
  const focusSession = sessionRows.find(item => item.session_id === activeSessionId) ?? null
  const keeperRows = mission.keeper_briefs.slice(0, 6).map(enrichedKeeperRow)
  const attentionQueue = mission.attention_queue
    .filter(item => item.related_session_ids.length > 0)
    .slice(0, 6)
  const internalSignals = mission.internal_signals.slice(0, 3)
  const attentionSessions = sessionRows.filter(row =>
    row.top_attention != null || row.related_attention_count > 0
  ).length
  const blockerSessions = sessionRows.filter(row => Boolean(row.blocker_summary)).length
  const eventRecordedSessions = sessionRows.filter(row =>
    Boolean(row.last_event_summary) || Boolean(row.last_event_at)
  ).length
  const participantPreviewNames = new Set<string>()
  const outputPreviewNames = new Set<string>()
  for (const session of sessionRows) {
    for (const preview of session.member_previews ?? []) {
      participantPreviewNames.add(preview.agent_name)
      if (preview.recent_output_preview) outputPreviewNames.add(preview.agent_name)
    }
  }
  const participantPreviewCount = participantPreviewNames.size
  const outputPreviewParticipantCount = outputPreviewNames.size
  const keeperStatusWarnings = keeperRows.filter(row => {
    const status = (row.brief.status ?? '').trim().toLowerCase()
    return status !== '' && status !== 'ok'
  }).length
  const outputPreviewSilentSessions = sessionRows.filter(row => {
    const memberPreviews = row.member_previews ?? []
    return memberPreviews.length === 0
      || memberPreviews.every(member => !member.recent_output_preview)
  }).length
  const focusSessionOutputs = ((focusSession?.member_previews ?? []) as Array<{
    agent_name?: string | null
    role?: string | null
    recent_output_preview?: string | null
    status?: string | null
  }>).filter(row => row.recent_output_preview)
  const keeperOutputRows = keeperRows.filter(row => row.recentOutput).slice(0, 4)

  useEffect(() => {
    void refreshMissionSessionDetail(activeSessionId)
  }, [activeSessionId])

  return html`
    <section class="dashboard-panel mission-view">
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${toneClass(mission.summary.room_health)}">${statusLabel(mission.summary.room_health)}</span>
          <span class="command-chip">${mission.summary.project ?? '프로젝트 미지정'}${mission.summary.current_room ? ` · ${mission.summary.current_room}` : ''}</span>
          <span class="command-chip">${mission.generated_at ? relativeTime(mission.generated_at) : '기록 없음'}</span>
        </div>
      </div>

      <${MissionContextBar}
        cluster=${mission.summary.cluster}
        project=${mission.summary.project}
        room=${mission.summary.current_room}
        generatedAt=${mission.generated_at}
      />

      <div class="mission-stat-grid">
        <${SummaryStat}
          label="관찰 세션"
          value=${sessionRows.length}
          detail="실행 중 또는 최근 갱신된 팀 세션"
          tone=${focusSession?.top_attention?.severity ?? focusSession?.health ?? 'ok'}
        />
        <${SummaryStat}
          label="attention 세션"
          value=${attentionSessions}
          detail="top_attention 또는 related_attention_count"
          tone=${attentionSessions > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="blocker 세션"
          value=${blockerSessions}
          detail="blocker_summary가 있는 세션"
          tone=${blockerSessions > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="사건 기록 세션"
          value=${eventRecordedSessions}
          detail="last_event_at 또는 last_event_summary"
          tone=${eventRecordedSessions > 0 ? 'ok' : 'warn'}
        />
        <${SummaryStat}
          label="출력 preview 참여자"
          value=${outputPreviewParticipantCount}
          detail=${participantPreviewCount > 0 ? `participant preview ${participantPreviewCount}명 중` : 'participant preview 없음'}
          tone=${outputPreviewParticipantCount > 0 ? 'ok' : 'warn'}
        />
        <${SummaryStat}
          label="비-ok 키퍼"
          value=${keeperStatusWarnings}
          detail=${keeperRows.length > 0 ? `keeper brief ${keeperRows.length}명 중` : 'keeper brief 없음'}
          tone=${keeperStatusWarnings > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="출력 preview 없는 세션"
          value=${outputPreviewSilentSessions}
          detail="recent_output_preview가 없는 세션"
          tone=${outputPreviewSilentSessions > 0 ? 'warn' : 'ok'}
        />
      </div>

      <nav class="mission-jump-strip">
        <a class="mission-jump-link" href="#mission-sessions">세션 ${sessionRows.length}</a>
        <a class="mission-jump-link" href="#mission-keepers">키퍼 ${keeperRows.length}</a>
        <a class="mission-jump-link" href="#mission-output">활동</a>
        <a class="mission-jump-link" href="#mission-attention">우선순위 ${attentionQueue.length}</a>
      </nav>

      ${activeSessionId
        ? html`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${focusSession?.goal ?? activeSessionId}${activeAttention ? ` · ${activeAttention.summary}` : ''}</span>
              <button class="control-btn ghost" onClick=${clearMissionSelection}>선택 해제</button>
            </div>
          `
        : null}

      <${Card} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs" id="mission-sessions">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 읽고 사회의 현재 상태를 파악합니다.</p>
          <${ProvenanceStrip} items=${[{ kind: 'truth' }]} />
        </div>
        <div class="mission-list-stack">
          ${sessionRows.length > 0
            ? sessionRows.map(row => html`<${SessionBriefCard} key=${row.session_id} brief=${row} selected=${activeSessionId === row.session_id} />`)
            : html`<div class="empty-state">지금 보이는 팀 세션이 없습니다.</div>`}
        </div>
      <//>

      <${SessionDetailCard}
        detail=${missionSessionDetail.value}
        loading=${missionSessionDetailLoading.value}
        error=${missionSessionDetailError.value}
      />

      <details open id="mission-keepers" class="mission-collapsible-section">
        <summary class="mission-collapsible-summary">키퍼 연속성 <span class="monitor-pill">${keeperRows.length}</span>${keeperStatusWarnings > 0 ? html` <span class="monitor-pill warn">${keeperStatusWarnings} 주의</span>` : null}</summary>
        <${Card} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>세션 밖에서 움직이는 행위자</h3>
            <p>키퍼는 세션과 별개로 보고, 사회의 연속성과 장기 행위자 상태를 먼저 읽습니다.</p>
            <${ProvenanceStrip} items=${[{ kind: 'truth' }]} />
          </div>
          <div class="mission-activity-list">
            ${keeperRows.length > 0
              ? keeperRows.map(row => html`<${KeeperBriefCard} key=${row.brief.name} row=${row} />`)
              : html`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${() => navigate('status', { section: 'sessions' })}>세션 보기</button>
            <button class="control-btn ghost" onClick=${() => navigate('operations', { section: 'command' })}>지휘 진단면 보기</button>
          </div>
        <//>
      </details>

      <details open id="mission-output" class="mission-collapsible-section">
        <summary class="mission-collapsible-summary">최근 사회 활동 <span class="monitor-pill">${focusSessionOutputs.length + keeperOutputRows.length}</span></summary>
        <${Card} title="최근 사회 활동" class="mission-list-card" semanticId="mission.session_activity">
          <div class="mission-section-head">
            <h3>누가 방금 무엇을 했나</h3>
            <p>선택된 세션과 연결된 행위자의 최근 출력만 모아 읽고, 해석은 뒤로 미룹니다.</p>
            <${ProvenanceStrip} items=${[{ kind: 'truth' }]} />
          </div>
          <div class="mission-list-stack">
            ${focusSessionOutputs.length > 0
              ? focusSessionOutputs.slice(0, 4).map(row => html`
                  <div class="mission-inline-note">
                    <strong>${row.agent_name ?? 'unknown actor'}</strong>
                    ${row.role ? html` · ${row.role}` : null}
                    ${row.status ? html` · ${statusLabel(row.status)}` : null}
                    <div>${row.recent_output_preview}</div>
                  </div>
                `)
              : html`<div class="empty-state">선택된 세션에서 바로 읽을 최근 출력이 없습니다.</div>`}
            ${keeperOutputRows.length > 0
              ? keeperOutputRows.map(row => html`
                  <div class="mission-inline-note">
                    <strong>${row.brief.name}</strong>
                    <div>${row.recentOutput}</div>
                  </div>
                `)
              : null}
          </div>
        <//>
      </details>

      <details open id="mission-attention" class="mission-collapsible-section">
        <summary class="mission-collapsible-summary">세션 우선순위 <span class="monitor-pill${attentionQueue.length > 0 ? ' warn' : ''}">${attentionQueue.length}</span></summary>
        <${Card} title="세션 우선순위" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>주의 신호는 truth를 훑은 다음에만 읽고, 세션 집중 순서를 정하는 용도로만 씁니다.</p>
            <${ProvenanceStrip} items=${[{ kind: 'derived' }]} />
          </div>
          <div class="mission-lane-stack">
            ${attentionQueue.length > 0
              ? attentionQueue.map(item => html`<${AttentionCard} key=${item.id} item=${item} selected=${activeSelectedAttentionId === item.id} sessionLookup=${sessionLookup} />`)
              : html`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>
      </details>

      ${internalSignals.length > 0 ? html`
        <details class="mission-card-disclosure" style="margin-top: 12px;">
          <summary>내부 신호 ${internalSignals.length}</summary>
          <div class="mission-list-stack">
            ${internalSignals.map(item => html`<${InternalSignalCard} key=${item.id} item=${item} />`)}
          </div>
        </details>
      ` : null}
    </section>
  `
}

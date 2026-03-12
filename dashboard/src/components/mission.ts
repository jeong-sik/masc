import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
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
  MissionBriefingCard,
  AttentionCard,
  SessionBriefCard,
  SessionDetailCard,
  KeeperBriefCard,
  InternalSignalCard,
} from './mission-cards'

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

  const sessionRows = mission.sessions
  if (selectedSessionId.value && !sessionRows.some(item => item.session_id === selectedSessionId.value)) {
    selectedSessionId.value = null
  }

  const activeAttention = mission.attention_queue.find(item => item.id === selectedAttentionId.value) ?? null
  const attentionSessionId =
    activeAttention?.related_session_ids.find(id => sessionRows.some(item => item.session_id === id)) ?? null
  const activeSessionId = selectedSessionId.value ?? attentionSessionId ?? sessionRows[0]?.session_id ?? null
  const sessionLookup = sessionLookupById()
  const focusSession = sessionRows.find(item => item.session_id === activeSessionId) ?? null
  const keeperRows = mission.keeper_briefs.slice(0, 6).map(enrichedKeeperRow)
  const attentionQueue = mission.attention_queue
    .filter(item => item.related_session_ids.length > 0)
    .slice(0, 6)
  const internalSignals = mission.internal_signals.slice(0, 3)
  const blockedSessions = sessionRows.filter(row => {
    const tone = row.top_attention?.severity ?? row.health ?? row.status
    return toneClass(tone) !== 'ok' || Boolean(row.blocker_summary)
  }).length
  const activeParticipants = new Set(
    sessionRows.flatMap(row => row.member_names),
  ).size
  const liveOutputs =
    sessionRows.flatMap(row => row.member_previews ?? []).filter(row => row.recent_output_preview).length
    + keeperRows.filter(row => row.recentOutput).length

  useEffect(() => {
    void refreshMissionSessionDetail(activeSessionId)
  }, [activeSessionId])

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="mission" />
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

      <${MissionBriefingCard} />

      <div class="mission-stat-grid">
        <${SummaryStat} label="활성 세션" value=${sessionRows.length} detail="지금 진행중인 협업 단위" tone=${focusSession?.top_attention?.severity ?? focusSession?.health ?? 'ok'} />
        <${SummaryStat} label="막힌 세션" value=${blockedSessions} detail="주의가 필요한 흐름" tone=${blockedSessions > 0 ? 'warn' : 'ok'} />
        <${SummaryStat} label="참여자" value=${activeParticipants} detail="현재 세션에 연결된 주체" tone=${activeParticipants > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="키퍼 관찰" value=${keeperRows.length} detail="연속성 확인 대상" tone=${keeperRows[0]?.brief.status ?? 'ok'} />
        <${SummaryStat} label="최근 응답" value=${liveOutputs} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${liveOutputs > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="내부 신호" value=${internalSignals.length} detail="시스템 진단은 보조 면에만 유지" tone=${internalSignals[0]?.severity ?? 'ok'} />
      </div>

      ${activeSessionId
        ? html`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${focusSession?.goal ?? activeSessionId}${activeAttention ? ` · ${activeAttention.summary}` : ''}</span>
              <button class="control-btn ghost" onClick=${clearMissionSelection}>선택 해제</button>
            </div>
          `
        : null}

      <${Card} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${sessionRows.length > 0
            ? sessionRows.map(row => html`<${SessionBriefCard} key=${row.session_id} brief=${row} selected=${activeSessionId === row.session_id} />`)
            : html`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${SessionDetailCard}
        detail=${missionSessionDetail.value}
        loading=${missionSessionDetailLoading.value}
        error=${missionSessionDetailError.value}
      />

      <div class="mission-human-grid">
        <${Card} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${attentionQueue.length > 0
              ? attentionQueue.map(item => html`<${AttentionCard} key=${item.id} item=${item} selected=${selectedAttentionId.value === item.id} sessionLookup=${sessionLookup} />`)
              : html`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${Card} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${internalSignals.length}</summary>
            <div class="mission-list-stack">
              ${internalSignals.length > 0
                ? internalSignals.map(item => html`<${InternalSignalCard} key=${item.id} item=${item} />`)
                : html`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${Card} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>연속성 보조 면</h3>
          <p>키퍼는 세션과 별개로 보고, 연속성 판단에 필요한 정보만 먼저 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${keeperRows.length > 0
            ? keeperRows.map(row => html`<${KeeperBriefCard} key=${row.brief.name} row=${row} />`)
            : html`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${() => navigate('execution')}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${() => navigate('command')}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `
}

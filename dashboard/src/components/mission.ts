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
import { ProvenanceStrip } from './common/provenance-strip'

const RECENT_SESSION_CHANGE_WINDOW_MS = 15 * 60 * 1000
const QUIET_KEEPER_TURN_WINDOW_SEC = 30 * 60

function isRecentTimestamp(iso?: string | null, windowMs = RECENT_SESSION_CHANGE_WINDOW_MS): boolean {
  if (!iso) return false
  const timestamp = Date.parse(iso)
  return !Number.isNaN(timestamp) && Date.now() - timestamp <= windowMs
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
  const urgentSessions = sessionRows.filter(row => {
    const tone = row.top_attention?.severity ?? row.health ?? row.status
    return Boolean(row.blocker_summary)
      || row.top_recommendation != null
      || toneClass(tone) !== 'ok'
  }).length
  const criticalSessions = sessionRows.filter(row => {
    const tone = row.top_attention?.severity ?? row.health ?? row.status
    return toneClass(tone) === 'bad'
  }).length
  const recentlyChangedSessions = sessionRows.filter(row =>
    isRecentTimestamp(row.last_event_at) || isRecentTimestamp(row.started_at)
  ).length
  const participantSignals = new Map<string, { responded: boolean }>()
  for (const session of sessionRows) {
    for (const preview of session.member_previews ?? []) {
      const existing = participantSignals.get(preview.agent_name) ?? { responded: false }
      participantSignals.set(preview.agent_name, {
        responded: existing.responded || Boolean(preview.recent_output_preview),
      })
    }
  }
  const observedParticipants = participantSignals.size
  const respondingParticipants =
    [...participantSignals.values()].filter(item => item.responded).length
  const unansweredParticipants = Math.max(observedParticipants - respondingParticipants, 0)
  const quietKeepers = keeperRows.filter(row => {
    const statusTone = toneClass(row.brief.status ?? row.keeper?.status)
    const staleTurn =
      typeof row.brief.last_turn_ago_s === 'number'
      && row.brief.last_turn_ago_s >= QUIET_KEEPER_TURN_WINDOW_SEC
    return statusTone !== 'ok' || (staleTurn && !row.recentOutput)
  }).length
  const responseSilentSessions = sessionRows.filter(row =>
    row.member_previews.length === 0
    || row.member_previews.every(member => !member.recent_output_preview)
  ).length
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

      <div class="mission-stat-grid">
        <${SummaryStat}
          label="활성 세션"
          value=${sessionRows.length}
          detail=${urgentSessions > 0 ? `${Math.max(sessionRows.length - urgentSessions, 0)}개 안정 흐름` : '지금 진행중인 협업 단위'}
          tone=${criticalSessions > 0 ? 'warn' : focusSession?.top_attention?.severity ?? focusSession?.health ?? 'ok'}
        />
        <${SummaryStat}
          label="즉시 개입 필요"
          value=${urgentSessions}
          detail="blocker·주의 신호·추천 액션"
          tone=${criticalSessions > 0 ? 'bad' : urgentSessions > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="무응답 참여자"
          value=${unansweredParticipants}
          detail=${observedParticipants > 0 ? `응답 흔적 ${respondingParticipants}/${observedParticipants}명` : '참여자 preview 없음'}
          tone=${unansweredParticipants > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="최근 변화 세션"
          value=${recentlyChangedSessions}
          detail="최근 15분 내 사건 또는 시작"
          tone=${recentlyChangedSessions > 0 ? 'ok' : 'warn'}
        />
        <${SummaryStat}
          label="조용한 키퍼"
          value=${quietKeepers}
          detail=${keeperRows.length > 0 ? `관찰 대상 ${keeperRows.length}명 중` : '연속성 확인 대상 없음'}
          tone=${quietKeepers > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="최근 응답 없는 세션"
          value=${responseSilentSessions}
          detail="활성 세션 중 출력 미관측"
          tone=${responseSilentSessions > 0 ? 'warn' : 'ok'}
        />
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
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 읽고 사회의 현재 상태를 파악합니다.</p>
          <${ProvenanceStrip} items=${[{ kind: 'truth' }]} />
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
          <button class="control-btn ghost" onClick=${() => navigate('execution')}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${() => navigate('command')}>지휘 진단면 보기</button>
        </div>
      <//>

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

      <${Card} title="세션 우선순위" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>어느 세션을 먼저 봐야 하나</h3>
          <p>주의 신호는 truth를 훑은 다음에만 읽고, 세션 집중 순서를 정하는 용도로만 씁니다.</p>
          <${ProvenanceStrip} items=${[{ kind: 'derived' }]} />
        </div>
        <div class="mission-lane-stack">
          ${attentionQueue.length > 0
            ? attentionQueue.map(item => html`<${AttentionCard} key=${item.id} item=${item} selected=${selectedAttentionId.value === item.id} sessionLookup=${sessionLookup} />`)
            : html`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${MissionBriefingCard} />

        <${Card} title="운영 보조 진단" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 사회 흐름을 읽은 뒤에만 참고하도록 아래 보조 면으로 둡니다.</p>
            <${ProvenanceStrip} items=${[{ kind: 'derived' }]} />
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
    </section>
  `
}

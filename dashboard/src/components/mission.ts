import { html } from 'htm/preact'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { isKeeperAgent } from './common/agent-info'
import { navigate } from '../router'
import {
  missionError,
  missionLoading,
  missionSnapshot,
} from '../mission-store'
import {
  selectedAttentionId,
  selectedSessionId,
  sessionLookupById,
  enrichedAgentRow,
  enrichedKeeperRow,
  clearMissionSelection,
  toneClass,
  relativeTime,
} from './mission-utils'
import {
  MissionContextBar,
  SummaryStat,
  MissionBriefingCard,
  AttentionCard,
  SessionBriefCard,
  AgentBriefCard,
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
  if (selectedSessionId.value && !mission.session_briefs.some(item => item.session_id === selectedSessionId.value)) {
    selectedSessionId.value = null
  }

  const activeAttention =
    mission.attention_queue.find(item => item.id === selectedAttentionId.value) ?? null
  const activeSessionId = selectedSessionId.value
  const sessionLookup = sessionLookupById()
  const activeSessionSet = activeAttention ? new Set(activeAttention.related_session_ids) : null
  const activeAgentSet = activeAttention ? new Set(activeAttention.related_agent_names) : null

  const sessionRows = (activeSessionSet
    ? mission.session_briefs.filter(item => activeSessionSet.has(item.session_id))
    : mission.session_briefs
  ).slice(0, activeAttention ? 8 : 6)

  const agentRows = mission.agent_briefs
    .filter(item => !isKeeperAgent(item.agent_name))
    .filter(item => {
      if (activeSessionId) return item.related_session_id === activeSessionId
      if (activeAgentSet && activeSessionSet) {
        return activeAgentSet.has(item.agent_name) || (item.related_session_id ? activeSessionSet.has(item.related_session_id) : false)
      }
      return true
    })
    .slice(0, activeSessionId || activeAttention ? 10 : 8)
    .map(enrichedAgentRow)

  const keeperRows = mission.keeper_briefs.slice(0, 6).map(enrichedKeeperRow)
  const attentionQueue = mission.attention_queue.slice(0, 6)
  const internalSignals = mission.internal_signals.slice(0, 3)
  const liveOutputs =
    agentRows.filter(row => row.recentOutput).length + keeperRows.filter(row => row.recentOutput).length

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${toneClass(mission.summary.room_health)}">${mission.summary.room_health ?? 'ok'}</span>
          <span class="command-chip">${mission.summary.project ?? 'room'}${mission.summary.current_room ? ` · ${mission.summary.current_room}` : ''}</span>
          <span class="command-chip">${mission.generated_at ? relativeTime(mission.generated_at) : 'fresh'}</span>
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
        <${SummaryStat} label="주의 큐" value=${attentionQueue.length} detail="개입 판단이 필요한 issue" tone=${attentionQueue[0]?.severity ?? 'ok'} />
        <${SummaryStat} label="영향 session" value=${sessionRows.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${sessionRows[0]?.top_attention?.severity ?? sessionRows[0]?.health ?? 'ok'} />
        <${SummaryStat} label="영향 agent" value=${agentRows.length} detail="선택된 흐름에 연결된 actor" tone=${agentRows[0]?.brief.status ?? 'ok'} />
        <${SummaryStat} label="Keeper watch" value=${keeperRows.length} detail="continuity lane 관찰 대상" tone=${keeperRows[0]?.brief.status ?? 'ok'} />
        <${SummaryStat} label="최근 output" value=${liveOutputs} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${liveOutputs > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="내부 신호" value=${internalSignals.length} detail="room/system 진단은 하단 보조 lane" tone=${internalSignals[0]?.severity ?? 'ok'} />
      </div>

      ${(activeAttention || activeSessionId)
        ? html`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${activeAttention ? activeAttention.summary : 'session 선택'}${activeSessionId ? ` · ${activeSessionId}` : ''}</span>
              <button class="control-btn ghost" onClick=${clearMissionSelection}>선택 해제</button>
            </div>
          `
        : null}

      <${Card} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${attentionQueue.length > 0
            ? attentionQueue.map(item => html`<${AttentionCard} key=${item.id} item=${item} selected=${selectedAttentionId.value === item.id} sessionLookup=${sessionLookup} />`)
            : html`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${Card} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${sessionRows.length > 0
              ? sessionRows.map(row => html`<${SessionBriefCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)
              : html`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${agentRows.length > 0
              ? agentRows.map(row => html`<${AgentBriefCard} key=${row.brief.agent_name} row=${row} />`)
              : html`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>continuity lane</h3>
            <p>keeper는 별도 lane으로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${keeperRows.length > 0
              ? keeperRows.map(row => html`<${KeeperBriefCard} key=${row.brief.name} row=${row} />`)
              : html`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${internalSignals.length > 0
              ? internalSignals.map(item => html`<${InternalSignalCard} key=${item.id} item=${item} />`)
              : html`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${() => navigate('execution')}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${() => navigate('command')}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `
}

import { html } from 'htm/preact'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { navigate } from '../router'
import { missionError, missionLoading, missionSnapshot } from '../mission-store'
import type { OperatorAttentionItem, OperatorRecommendedAction, OperatorSessionCard } from '../types'

function toneClass(tone?: string | null): string {
  if (tone === 'bad') return 'bad'
  if (tone === 'warn' || tone === 'pending') return 'warn'
  return 'ok'
}

function relativeTime(iso?: string | null): string {
  if (!iso) return '방금'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}s 전`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}m 전`
  return `${Math.round(deltaSec / 3600)}h 전`
}

function nextActionRoute(action?: OperatorRecommendedAction | null): () => void {
  if (!action) {
    return () => navigate('intervene')
  }
  if (action.target_type === 'room' || action.target_type === 'team_session' || action.target_type === 'keeper') {
    return () => navigate('intervene')
  }
  return () => navigate('command')
}

function SummaryStat({
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

function IncidentCard({ item }: { item: OperatorAttentionItem }) {
  return html`
    <article class="mission-incident-card ${toneClass(item.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${toneClass(item.severity)}">${item.severity}</span>
        <span class="mission-card-target">${item.target_type}${item.target_id ? ` · ${item.target_id}` : ''}</span>
      </div>
      <strong>${item.summary}</strong>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${() => navigate('intervene')}>개입 열기</button>
        <button class="control-btn ghost" onClick=${() => navigate('command')}>지휘면 보기</button>
      </div>
    </article>
  `
}

function RecommendedActionCard({ action }: { action: OperatorRecommendedAction }) {
  return html`
    <article class="mission-action-card ${toneClass(action.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${toneClass(action.severity)}">${action.action_type}</span>
        <span class="mission-card-target">${action.target_type}${action.target_id ? ` · ${action.target_id}` : ''}</span>
      </div>
      <p>${action.reason}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${nextActionRoute(action)}>개입 워크스페이스</button>
      </div>
    </article>
  `
}

function SessionFocusCard({ session }: { session: OperatorSessionCard }) {
  return html`
    <article class="mission-session-card ${toneClass(session.health)}">
      <div class="mission-card-head">
        <strong>${session.goal ?? session.session_id}</strong>
        <span class="command-chip ${toneClass(session.health)}">${session.health ?? 'ok'}</span>
      </div>
      <div class="mission-session-meta">
        <span>${session.status ?? 'unknown'}</span>
        <span>worker ${session.active_agent_count ?? 0}/${session.planned_worker_count ?? 0}</span>
        <span>${session.last_turn_age_sec != null ? `${session.last_turn_age_sec}s ago` : 'freshness n/a'}</span>
      </div>
      <div class="mission-session-summary">
        <span>attention ${session.attention_count ?? 0}</span>
        <span>action ${session.recommended_action_count ?? 0}</span>
      </div>
    </article>
  `
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

  const summary = mission.summary
  const topIncident = mission.incidents[0] ?? summary.top_attention ?? null
  const topAction = mission.recommended_actions[0] ?? summary.top_action ?? null
  const sessions = mission.command_focus.session_cards.slice(0, 3)
  const keepers = mission.operator_targets.keepers.slice(0, 4)

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 문제, 다음 액션, 운영 포커스를 한 번에 보는 운영 랜딩입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${toneClass(summary.room_health)}">${summary.room_health ?? 'ok'}</span>
          <span class="command-chip">${summary.project ?? 'room'}${summary.current_room ? ` · ${summary.current_room}` : ''}</span>
          <span class="command-chip">${mission.generated_at ? relativeTime(mission.generated_at) : 'fresh'}</span>
        </div>
      </div>

      <div class="mission-stat-grid">
        <${SummaryStat} label="활성 에이전트" value=${summary.active_agents ?? 0} detail="실시간 응답 가능한 agent 수" tone=${summary.active_agents && summary.active_agents > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="Keeper 압력" value=${summary.keeper_pressure ?? 0} detail="stale / hot keeper 수" tone=${(summary.keeper_pressure ?? 0) > 0 ? 'warn' : 'ok'} />
        <${SummaryStat} label="활성 작전" value=${summary.active_operations ?? 0} detail="command plane active operation" tone=${(summary.active_operations ?? 0) > 0 ? 'ok' : 'warn'} />
        <${SummaryStat} label="승인 대기" value=${summary.pending_approvals ?? 0} detail="사람 확인이 필요한 decision" tone=${(summary.pending_approvals ?? 0) > 0 ? 'warn' : 'ok'} />
        <${SummaryStat} label="우선 Incident" value=${summary.incident_count ?? mission.incidents.length} detail="지금 우선순위로 볼 attention item" tone=${topIncident?.severity ?? 'ok'} />
        <${SummaryStat} label="다음 액션" value=${summary.recommended_action_count ?? mission.recommended_actions.length} detail="digest 기준 추천 액션 수" tone=${topAction?.severity ?? 'ok'} />
      </div>

      <div class="mission-primary-grid">
        <${Card} title="지금 가장 먼저 볼 것" class="mission-hero-card" semanticId="mission.hero">
          ${topIncident
            ? html`
                <div class="mission-priority-block ${toneClass(topIncident.severity)}">
                  <div class="mission-card-head">
                    <span class="command-chip ${toneClass(topIncident.severity)}">${topIncident.kind}</span>
                    <span class="mission-card-target">${topIncident.target_type}${topIncident.target_id ? ` · ${topIncident.target_id}` : ''}</span>
                  </div>
                  <strong>${topIncident.summary}</strong>
                </div>
              `
            : html`<div class="empty-state">우선 incident가 없습니다.</div>`}
          ${topAction
            ? html`
                <div class="mission-action-highlight">
                  <div class="mission-card-head">
                    <span class="command-chip ${toneClass(topAction.severity)}">${topAction.action_type}</span>
                    <span class="mission-card-target">${topAction.target_type}${topAction.target_id ? ` · ${topAction.target_id}` : ''}</span>
                  </div>
                  <p>${topAction.reason}</p>
                  <div class="mission-card-actions">
                    <button class="control-btn ghost" onClick=${nextActionRoute(topAction)}>개입하러 가기</button>
                    <button class="control-btn ghost" onClick=${() => navigate('command', { surface: 'swarm' })}>지휘면 상세</button>
                  </div>
                </div>
              `
            : null}
        <//>

        <${Card} title="운영 포커스" class="mission-focus-card" semanticId="mission.focus">
          <div class="mission-focus-grid">
            <div class="mission-focus-item">
              <span>지휘 건강도</span>
              <strong class=${toneClass(mission.command_focus.health)}>${mission.command_focus.health ?? 'ok'}</strong>
            </div>
            <div class="mission-focus-item">
              <span>활성 레인</span>
              <strong>${mission.command_focus.swarm_overview?.active_lanes ?? 0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>이동 레인</span>
              <strong>${mission.command_focus.swarm_overview?.moving_lanes ?? 0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>마지막 이동</span>
              <strong>${relativeTime(mission.command_focus.swarm_overview?.last_movement_at)}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${() => navigate('command')}>지휘면 열기</button>
            <button class="control-btn ghost" onClick=${() => navigate('command', { surface: 'swarm' })}>스웜 상세</button>
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${Card} title="우선 Incident" class="mission-list-card" semanticId="mission.incidents">
          <div class="mission-list-stack">
            ${mission.incidents.length > 0
              ? mission.incidents.slice(0, 5).map(item => html`<${IncidentCard} item=${item} />`)
              : html`<div class="empty-state">attention item이 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="추천 액션" class="mission-list-card" semanticId="mission.actions">
          <div class="mission-list-stack">
            ${mission.recommended_actions.length > 0
              ? mission.recommended_actions.slice(0, 4).map(action => html`<${RecommendedActionCard} action=${action} />`)
              : html`<div class="empty-state">추천 액션이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${Card} title="집중 세션" class="mission-list-card" semanticId="mission.sessions">
          <div class="mission-list-stack">
            ${sessions.length > 0
              ? sessions.map(session => html`<${SessionFocusCard} session=${session} />`)
              : html`<div class="empty-state">지금 강조할 session이 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="바로 개입할 대상" class="mission-list-card" semanticId="mission.targets">
          <div class="mission-target-grid">
            <div class="mission-target-block">
              <span class="mission-target-title">Keepers</span>
              ${keepers.length > 0
                ? keepers.map(keeper => html`<div class="mission-target-row"><strong>${keeper.name}</strong><span class="command-chip ${toneClass(keeper.status)}">${keeper.status ?? 'unknown'}</span></div>`)
                : html`<div class="mission-target-empty">keeper 대상이 없습니다.</div>`}
            </div>
            <div class="mission-target-block">
              <span class="mission-target-title">대기 중 confirm</span>
              <strong>${mission.operator_targets.pending_confirms.length}</strong>
              <span class="mission-target-title">가능 액션</span>
              <strong>${mission.operator_targets.available_actions.length}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${() => navigate('intervene')}>개입 워크스페이스</button>
          </div>
        <//>
      </div>
    </section>
  `
}

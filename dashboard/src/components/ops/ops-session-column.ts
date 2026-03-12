// Ops — Session column: session list, selected session digest, session actions

import { html } from 'htm/preact'
import { PanelSemanticDetails } from '../common/semantic-layer'
import {
  operatorActionBusy,
  operatorSessionDigest,
  operatorSnapshot,
} from '../../operator-store'
import {
  actionTypeLabel,
  displayStatus,
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  deliveryModeLabel,
  prettyJson,
  runtimeJudgeLabel,
  selectedSessionId,
  sessionActionLabel,
  submitTeamStop,
  submitTeamTurn,
  targetTypeLabel,
  teamMessage,
  teamSpawnBatchJson,
  teamStopReason,
  teamTaskDescription,
  teamTaskPriority,
  teamTaskTitle,
  teamTurnKind,
} from './helpers'

export function OpsSessionColumn() {
  const snapshot = operatorSnapshot.value
  const sessionDigest = operatorSessionDigest.value
  const sessions = snapshot?.sessions ?? []
  const availableSessionActions = (snapshot?.available_actions ?? []).filter(action => action.target_type === 'team_session')
  const selectedSession = sessions.find(session => session.session_id === selectedSessionId.value) ?? sessions[0] ?? null
  const activeSummary = sessionDigest?.active_summary
  const guidanceLayer = sessionDigest?.active_guidance_layer ?? 'fallback'
  const residentRuntime = sessionDigest?.resident_judge_runtime ?? snapshot?.resident_judge_runtime
  const activeRecommendedActions =
    sessionDigest?.active_recommended_actions?.length
      ? sessionDigest.active_recommended_actions
      : sessionDigest?.recommended_actions ?? []

  return html`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${PanelSemanticDetails} panelId="intervene.session_queue" compact=${true} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${sessions.length === 0 ? html`<div class="ops-empty">지금 활성 team session이 없습니다.</div>` : sessions.map(session => html`
            <button
              key=${session.session_id}
              class="ops-entity-card ${selectedSession?.session_id === session.session_id ? 'active' : ''}"
              onClick=${() => { selectedSessionId.value = session.session_id }}
            >
              <div class="ops-entity-title-row">
                <strong>${session.session_id}</strong>
                <span class="status-badge ${session.status ?? 'idle'}">${displayStatus(session.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(session.progress_pct ?? 0)}%</span>
                <span>${session.done_delta_total ?? 0}건 완료</span>
                <span>${session.team_health?.status ? displayStatus(String(session.team_health.status)) : '상태 확인 필요'}</span>
              </div>
            </button>
          `)}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${PanelSemanticDetails} panelId="intervene.session_digest" compact=${true} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${selectedSession && sessionDigest ? html`
          <article class="ops-guidance-card ${guidanceLayerTone(guidanceLayer)}">
            <div class="ops-guidance-head">
              <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
              <span>${runtimeJudgeLabel(residentRuntime)}</span>
            </div>
            <div class="ops-guidance-body">
              ${activeSummary?.summary ?? '현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다.'}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${sessionDigest.authoritative_judgment_available ? 'yes' : 'no'}</span>
              <span>${guidanceFreshnessLabel(activeSummary)}</span>
              ${residentRuntime?.model_used ? html`<span>${residentRuntime.model_used}</span>` : null}
            </div>
          </article>
          ${activeRecommendedActions.length > 0 ? html`
            <div class="ops-log-list">
              ${activeRecommendedActions.map(item => html`
                <article key=${`${item.action_type}:${item.target_type}:${item.target_id ?? 'session'}`} class="ops-log-entry ${item.severity}">
                  <div class="ops-log-head">
                    <strong>${actionTypeLabel(item.action_type)}</strong>
                    <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                  </div>
                  <div class="ops-log-body">${item.reason}</div>
                </article>
              `)}
            </div>
          ` : null}
          <div class="ops-log-list">
            ${sessionDigest.attention_items.length > 0 ? sessionDigest.attention_items.map(item => html`
              <article key=${`${item.kind}:${item.target_id ?? 'session'}`} class="ops-log-entry ${item.severity}">
                <div class="ops-log-head">
                  <strong>${item.kind}</strong>
                  <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                </div>
                <div class="ops-log-body">${item.summary}</div>
              </article>
            `) : html`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${sessionDigest.worker_cards.length > 0 ? sessionDigest.worker_cards.map(card => html`
              <article key=${`${card.actor ?? card.spawn_role ?? 'worker'}:${card.spawn_agent ?? card.runtime_pool ?? 'runtime'}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${card.actor ?? card.spawn_role ?? 'worker'}</strong>
                  <span>${displayStatus(card.status)}</span>
                  <span>${card.spawn_agent ?? card.runtime_pool ?? 'runtime 확인 필요'}</span>
                </div>
                <div class="ops-log-body">
                  ${(card.worker_class ?? 'worker')}${card.lane_id ? ` · ${card.lane_id}` : ''}${card.routing_reason ? ` · ${card.routing_reason}` : ''}
                </div>
              </article>
            `) : null}
          </div>
        ` : html`
          <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
        `}
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 액션</div>
          <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${availableSessionActions.length > 0 ? html`
          <div class="ops-log-list">
            ${availableSessionActions.map(action => html`
              <article key=${action.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${actionTypeLabel(action.action_type)}</strong>
                  <span>${deliveryModeLabel(action.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${action.description ?? '설명 확인 필요'}</div>
              </article>
            `)}
          </div>
        ` : null}

        ${selectedSession ? html`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${selectedSession.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${displayStatus(selectedSession.status)}</span>
              <span>경과: ${selectedSession.elapsed_sec ?? 0}초</span>
              <span>남은 시간: ${selectedSession.remaining_sec ?? 0}초</span>
            </div>
            ${selectedSession.linked_autoresearch ? html`
              <div class="ops-detail-meta">
                <span>Autoresearch: ${String(selectedSession.linked_autoresearch.status ?? 'unknown')}</span>
                <span>Loop: ${String(selectedSession.linked_autoresearch.loop_id ?? 'n/a')}</span>
                <span>Cycle: ${String(selectedSession.linked_autoresearch.current_cycle ?? 0)}</span>
                <span>Best: ${String(selectedSession.linked_autoresearch.best_score ?? 'n/a')}</span>
              </div>
            ` : null}
            ${selectedSession.recent_events && selectedSession.recent_events.length > 0 ? html`
              <pre class="ops-code-block compact">${prettyJson(selectedSession.recent_events.slice(-3))}</pre>
            ` : null}
          </div>
        ` : html`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${teamTurnKind.value}
            onChange=${(event: Event) => { teamTurnKind.value = (event.target as HTMLSelectElement).value as typeof teamTurnKind.value }}
            disabled=${operatorActionBusy.value || !selectedSession}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${() => { void submitTeamTurn() }} disabled=${operatorActionBusy.value || !selectedSession}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${sessionActionLabel(teamTurnKind.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${teamMessage.value}
          onInput=${(event: Event) => { teamMessage.value = (event.target as HTMLTextAreaElement).value }}
          disabled=${operatorActionBusy.value || !selectedSession}
        ></textarea>

        ${teamTurnKind.value === 'task' ? html`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${teamTaskTitle.value}
            onInput=${(event: Event) => { teamTaskTitle.value = (event.target as HTMLInputElement).value }}
            disabled=${operatorActionBusy.value || !selectedSession}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${teamTaskDescription.value}
            onInput=${(event: Event) => { teamTaskDescription.value = (event.target as HTMLTextAreaElement).value }}
            disabled=${operatorActionBusy.value || !selectedSession}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${teamTaskPriority.value}
            onChange=${(event: Event) => { teamTaskPriority.value = (event.target as HTMLSelectElement).value }}
            disabled=${operatorActionBusy.value || !selectedSession}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        ` : teamTurnKind.value === 'worker_spawn_batch' ? html`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${teamSpawnBatchJson.value}
            onInput=${(event: Event) => { teamSpawnBatchJson.value = (event.target as HTMLTextAreaElement).value }}
            disabled=${operatorActionBusy.value || !selectedSession}
          ></textarea>
        ` : null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${teamStopReason.value}
            onInput=${(event: Event) => { teamStopReason.value = (event.target as HTMLInputElement).value }}
            disabled=${operatorActionBusy.value || !selectedSession}
          />
          <button class="control-btn ghost" onClick=${() => { void submitTeamStop() }} disabled=${operatorActionBusy.value || !selectedSession}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `
}

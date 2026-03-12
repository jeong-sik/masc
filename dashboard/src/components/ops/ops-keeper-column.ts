// Ops — Keeper column: keeper list, keeper actions, available actions, recent action log

import { html } from 'htm/preact'
import { PanelSemanticDetails } from '../common/semantic-layer'
import { KeeperConversationPanel } from '../keeper-shared'
import {
  operatorActionLog,
  operatorSnapshot,
} from '../../operator-store'
import {
  actionTypeLabel,
  deliveryModeLabel,
  displayStatus,
  relativeAge,
  selectedKeeperName,
  targetTypeLabel,
} from './helpers'

export function OpsKeeperColumn() {
  const snapshot = operatorSnapshot.value
  const keepers = snapshot?.keepers ?? []
  const persistentAgents = snapshot?.persistent_agents ?? []
  const availableActions = snapshot?.available_actions ?? []
  const selectedKeeper = keepers.find(keeper => keeper.name === selectedKeeperName.value) ?? keepers[0] ?? null

  return html`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${PanelSemanticDetails} panelId="intervene.keeper_queue" compact=${true} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${keepers.length === 0 ? html`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>` : keepers.map(keeper => html`
            <button
              key=${keeper.name}
              class="ops-entity-card ${selectedKeeper?.name === keeper.name ? 'active' : ''}"
              onClick=${() => { selectedKeeperName.value = keeper.name }}
            >
              <div class="ops-entity-title-row">
                <strong>${keeper.name}</strong>
                <span class="status-badge ${keeper.status ?? 'idle'}">${displayStatus(keeper.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${keeper.model ?? 'model 확인 필요'}</span>
                <span>${typeof keeper.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}% ctx` : 'ctx 확인 필요'}</span>
                <span>${relativeAge(keeper.last_turn_ago_s)}</span>
              </div>
            </button>
          `)}
        </div>
        <div class="ops-context-note" style="margin-top:12px;">Persistent agent는 resident keeper와 분리해서 참고용으로만 보여줍니다.</div>
        <div class="ops-entity-list">
          ${persistentAgents.length === 0
            ? html`<div class="ops-empty">분리된 persistent agent는 없습니다.</div>`
            : persistentAgents.map(agent => html`
                <article key=${agent.name} class="ops-entity-card">
                  <div class="ops-entity-title-row">
                    <strong>${agent.name}</strong>
                    <span class="status-badge ${agent.status ?? 'idle'}">${displayStatus(agent.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${agent.model ?? 'model 확인 필요'}</span>
                    <span>${relativeAge(agent.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
        </div>
        <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${selectedKeeper ? html`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${selectedKeeper.name}</div>
            <div class="ops-detail-meta">
              <span>자율성: ${selectedKeeper.autonomy_level ?? '확인 없음'}</span>
              <span>세대: ${selectedKeeper.generation ?? 0}</span>
              <span>활성 목표: ${selectedKeeper.active_goal_ids?.length ?? 0}</span>
            </div>
          </div>
          <${KeeperConversationPanel}
            keeperName=${selectedKeeper.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        ` : html`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${availableActions.length
            ? availableActions.map(action => html`
                <article key=${`${action.action_type}:${action.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${actionTypeLabel(action.action_type)}</strong>
                    <span>${targetTypeLabel(action.target_type)}</span>
                    <span>${deliveryModeLabel(action.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${action.description ?? '설명이 아직 없습니다.'}</div>
                </article>
              `)
            : html`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${PanelSemanticDetails} panelId="intervene.recommended_actions" compact=${true} />
        </div>
        <div class="ops-log-list">
          ${operatorActionLog.value.length === 0 ? html`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          ` : operatorActionLog.value.map(entry => html`
            <article key=${entry.id} class="ops-log-entry ${entry.outcome}">
              <div class="ops-log-head">
                <strong>${actionTypeLabel(entry.action_type)}</strong>
                <span>${entry.target_label}</span>
                <span>${entry.at}</span>
              </div>
              <div class="ops-log-body">${entry.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `
}

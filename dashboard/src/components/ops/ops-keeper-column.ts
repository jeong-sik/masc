// Ops — Keeper column: keeper list, keeper actions, available actions, recent action log

import { html } from 'htm/preact'
import { KeeperConversationPanel } from '../keeper-shared'
import { openKeeperDetail } from '../keeper-detail'
import { findKeeper } from '../execution/shared'
import {
  operatorActionLog,
  operatorSnapshot,
} from '../../operator-store'
import type { Keeper, OperatorKeeperSnapshot } from '../../types'
import {
  actionTypeLabel,
  displayStatus,
  keeperPrioritySummary,
  keeperPriorityTone,
  relativeAge,
  selectedKeeperName,
  targetTypeLabel,
} from './helpers'

function truncateGoal(goal: string, maxLen = 60): string {
  return goal.length > maxLen ? goal.slice(0, maxLen) + '...' : goal
}

function openOpsKeeperDetail(opsKeeper: OperatorKeeperSnapshot): void {
  const full = findKeeper(opsKeeper.name)
  const keeper: Keeper = full ?? {
    name: opsKeeper.name,
    agent_name: opsKeeper.agent_name ?? opsKeeper.name,
    status: opsKeeper.status ?? 'unknown',
    context_ratio: opsKeeper.context_ratio ?? null,
    model: opsKeeper.model ?? null,
    goal: opsKeeper.goal ?? null,
  } as Keeper
  openKeeperDetail(keeper)
}

export function OpsKeeperColumn() {
  const snapshot = operatorSnapshot.value
  const keepers = snapshot?.keepers ?? []
  const persistentAgents = snapshot?.persistent_agents ?? []
  const availableActions = snapshot?.available_actions ?? []
  const selectedKeeper = keepers.find(keeper => keeper.name === selectedKeeperName.value) ?? keepers[0] ?? null

  return html`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="card flex flex-col gap-3 min-h-0 ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
        </div>
        <p class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45]">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="flex items-center justify-between gap-2.5 text-[var(--fs-sm)] text-text-muted">
          ${keepers.length === 0 ? html`<div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">지금 보이는 keeper가 없습니다.</div>` : keepers.map(keeper => html`
            ${(() => {
              const tone = keeperPriorityTone(keeper)
              const prioritySummary = keeperPrioritySummary(keeper)
              return html`
            <button
              key=${keeper.name}
              class="ops-entity-card p-3 rounded-[10px] border border-[var(--white-8)] bg-[var(--white-3)] text-inherit text-left cursor-pointer ${selectedKeeper?.name === keeper.name ? 'active' : ''}"
              onClick=${() => { selectedKeeperName.value = keeper.name }}
            >
              <div class="flex justify-between items-center gap-2.5 max-[880px]:flex-col max-[880px]:items-start">
                <strong>${keeper.name}</strong>
                <span class="border border-solid border-[var(--card-border)] ${keeper.status ?? 'idle'} ${keeper.status === 'offline' ? 'text-[#8da4cc]' : ''}">${displayStatus(keeper.status)}</span>
                <span
                  class="ops-detail-link"
                  title="키퍼 상세 보기"
                  style="cursor:pointer; font-size:12px; opacity:0.6; margin-left:auto;"
                  onClick=${(e: Event) => { e.stopPropagation(); openOpsKeeperDetail(keeper) }}
                >상세</span>
              </div>
              <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                <span>${keeper.last_model_used ?? keeper.model ?? 'model 확인 필요'}</span>
                <span>${typeof keeper.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}% ctx` : typeof keeper.context_tokens === 'number' ? `${Math.round(keeper.context_tokens / 1000)}k tok` : 'ctx 확인 필요'}</span>
                <span>${relativeAge(keeper.last_turn_ago_s)}</span>
              </div>
              ${keeper.short_goal || keeper.goal ? html`
                <div class="text-[var(--fs-xs)] text-text-muted mt-1.5 p-1 px-1.5 bg-[var(--card)] rounded-[4px]" title=${keeper.goal ?? ''}>${truncateGoal(keeper.short_goal ?? keeper.goal ?? '')}</div>
              ` : null}
              ${tone !== 'ok'
                ? html`<div class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45] mt-1.5">점검 이유: ${prioritySummary}</div>`
                : null}
              <div class="flex gap-2 text-[var(--fs-2xs)] text-text-muted mt-0.5">
                ${typeof keeper.turn_count === 'number' ? html`<span>turns: ${keeper.turn_count}</span>` : null}
                ${typeof keeper.autonomous_action_count === 'number' ? html`<span>actions: ${keeper.autonomous_action_count}</span>` : null}
                ${keeper.keepalive_running ? html`<span class="keepalive-active">keepalive</span>` : null}
              </div>
            </button>
              `
            })()}
          `)}
        </div>
        <div class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45] mt-3">Persistent agent는 resident keeper와 분리해서 참고용으로만 보여줍니다.</div>
        <div class="flex items-center justify-between gap-2.5 text-[var(--fs-sm)] text-text-muted">
          ${persistentAgents.length === 0
            ? html`<div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">분리된 persistent agent는 없습니다.</div>`
            : persistentAgents.map(agent => html`
                <article key=${agent.name} class="ops-entity-card p-3 rounded-[10px] border border-[var(--white-8)] bg-[var(--white-3)] text-inherit text-left cursor-pointer">
                  <div class="flex justify-between items-center gap-2.5 max-[880px]:flex-col max-[880px]:items-start">
                    <strong>${agent.name}</strong>
                    <span class="border border-solid border-[var(--card-border)] ${agent.status ?? 'idle'} ${agent.status === 'offline' ? 'text-[#8da4cc]' : ''}">${displayStatus(agent.status)}</span>
                  </div>
                  <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                    <span>persistent</span>
                    <span>${agent.model ?? 'model 확인 필요'}</span>
                    <span>${relativeAge(agent.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
        </div>
        <p class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45]">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${selectedKeeper ? html`
          <div class="flex flex-col gap-2">
            <div class="mt-1.5 whitespace-pre-wrap break-words">${selectedKeeper.name}</div>
            <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
              <span>자율성: ${selectedKeeper.autonomy_level ?? '확인 없음'}</span>
              <span>세대: ${selectedKeeper.generation ?? 0}</span>
              <span>활성 목표: ${selectedKeeper.active_goal_ids?.length ?? 0}</span>
              ${typeof selectedKeeper.turn_count === 'number' ? html`<span>턴: ${selectedKeeper.turn_count}</span>` : null}
              ${selectedKeeper.last_model_used ? html`<span>모델: ${selectedKeeper.last_model_used}</span>` : null}
            </div>
            ${keeperPriorityTone(selectedKeeper) !== 'ok'
              ? html`<div class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45] mt-2">현재 점검 이유: ${keeperPrioritySummary(selectedKeeper)}</div>`
              : null}
            ${selectedKeeper.goal ? html`<div class="whitespace-normal mt-1.5 py-1 px-1.5 bg-[var(--card)] rounded-[4px] text-[var(--fs-xs)] text-text-muted">${selectedKeeper.goal}</div>` : null}
          </div>
          <${KeeperConversationPanel}
            keeperName=${selectedKeeper.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        ` : html`<div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card flex flex-col gap-3 min-h-0">
        <div class="card-title-row">
          <div class="card-title">액션</div>
          <span style="font-size:0.75rem;opacity:0.5">${availableActions.length}개</span>
        </div>
        ${availableActions.length
          ? html`<div style="display:flex;flex-direction:column;gap:0.5rem">
              ${['room', 'keeper', 'team_session'].map(targetType => {
                const group = availableActions.filter((a: any) => a.target_type === targetType)
                if (group.length === 0) return null
                return html`
                  <div key=${targetType}>
                    <div style="font-size:0.7rem;opacity:0.4;margin-bottom:0.25rem">${targetTypeLabel(targetType)}</div>
                    <div style="display:flex;flex-wrap:wrap;gap:0.25rem">
                      ${group.map((action: any) => html`
                        <span key=${action.action_type}
                          title=${action.description ?? ''}
                          style="font-size:0.75rem;padding:0.15rem 0.5rem;border-radius:4px;background:${action.confirm_required ? 'rgba(255,180,50,0.15)' : 'rgba(100,200,255,0.1)'};border:1px solid ${action.confirm_required ? 'rgba(255,180,50,0.3)' : 'rgba(100,200,255,0.2)'};cursor:default">
                          ${actionTypeLabel(action.action_type)}
                        </span>
                      `)}
                    </div>
                  </div>
                `
              })}
            </div>`
          : html`<div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">액션 없음</div>`}
      </section>

      <section class="card flex flex-col gap-3 min-h-0">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
        </div>
        <div class="flex flex-col gap-2">
          ${operatorActionLog.value.length === 0 ? html`
            <div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">이 세션에서 실행한 개입이 아직 없습니다.</div>
          ` : operatorActionLog.value.map(entry => html`
            <article key=${entry.id} class="ops-log-entry p-3 rounded-[10px] bg-[var(--white-3)] border border-[var(--white-8)] ${entry.outcome}">
              <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                <strong>${actionTypeLabel(entry.action_type)}</strong>
                <span>${entry.target_label}</span>
                <span>${entry.at}</span>
              </div>
              <div class="mt-1.5 whitespace-pre-wrap break-words">${entry.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `
}

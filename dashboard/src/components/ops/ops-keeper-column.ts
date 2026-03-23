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
  logEntryBorderClass,
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
      <section class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)] flex flex-col gap-3 min-h-0 ops-lane-panel ops-keeper-section">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">Keeper 개입</h3>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="flex flex-col gap-2">
          ${keepers.length === 0 ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">지금 보이는 keeper가 없습니다.</div>` : keepers.map(keeper => html`
            ${(() => {
              const tone = keeperPriorityTone(keeper)
              const prioritySummary = keeperPrioritySummary(keeper)
              return html`
            <button
              key=${keeper.name}
              class="ops-entity-card p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] text-inherit text-left cursor-pointer w-full ${selectedKeeper?.name === keeper.name ? 'active' : ''}"
              onClick=${() => { selectedKeeperName.value = keeper.name }}
            >
              <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
                <strong class="text-[13px] font-semibold">${keeper.name}</strong>
                <div class="flex items-center gap-2 ml-auto">
                  <span class="inline-flex items-center gap-1.5 text-[11px]">
                    <span class="w-2 h-2 rounded-full ${keeper.status === 'offline' ? 'bg-[var(--text-muted)]' : keeper.status === 'active' || keeper.status === 'running' ? 'bg-[var(--ok)]' : 'bg-[var(--warn)]'}"></span>
                    ${displayStatus(keeper.status)}
                  </span>
                  <span
                    class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] cursor-pointer transition-colors"
                    title="키퍼 상세 보기"
                    onClick=${(e: Event) => { e.stopPropagation(); openOpsKeeperDetail(keeper) }}
                  >상세</span>
                </div>
              </div>
              <div class="text-[11px] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                <span>${keeper.last_model_used ?? keeper.model ?? 'model 확인 필요'}</span>
                <span>${typeof keeper.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}% ctx` : typeof keeper.context_tokens === 'number' ? `${Math.round(keeper.context_tokens / 1000)}k tok` : 'ctx 확인 필요'}</span>
                <span>${relativeAge(keeper.last_turn_ago_s)}</span>
              </div>
              ${keeper.short_goal || keeper.goal ? html`
                <div class="text-[11px] text-[var(--text-muted)] mt-1.5 p-1 px-1.5 bg-[var(--white-3)] rounded" title=${keeper.goal ?? ''}>${truncateGoal(keeper.short_goal ?? keeper.goal ?? '')}</div>
              ` : null}
              ${tone !== 'ok'
                ? html`<div class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-1.5">점검 이유: ${prioritySummary}</div>`
                : null}
              <div class="flex gap-2 text-[10px] text-[var(--text-muted)] mt-1">
                ${typeof keeper.turn_count === 'number' ? html`<span>turns: ${keeper.turn_count}</span>` : null}
                ${typeof keeper.autonomous_action_count === 'number' ? html`<span>actions: ${keeper.autonomous_action_count}</span>` : null}
                ${keeper.keepalive_running ? html`<span class="text-[var(--ok)]">keepalive</span>` : null}
              </div>
            </button>
              `
            })()}
          `)}
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-3">Persistent agent는 resident keeper와 분리해서 참고용으로만 보여줍니다.</p>
        <div class="flex flex-col gap-2">
          ${persistentAgents.length === 0
            ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">분리된 persistent agent는 없습니다.</div>`
            : persistentAgents.map(agent => html`
                <article key=${agent.name} class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
                  <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
                    <strong class="text-[13px] font-semibold">${agent.name}</strong>
                    <span class="inline-flex items-center gap-1.5 text-[11px]">
                      <span class="w-2 h-2 rounded-full ${agent.status === 'offline' ? 'bg-[var(--text-muted)]' : 'bg-[var(--warn)]'}"></span>
                      ${displayStatus(agent.status)}
                    </span>
                  </div>
                  <div class="text-[11px] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                    <span>persistent</span>
                    <span>${agent.model ?? 'model 확인 필요'}</span>
                    <span>${relativeAge(agent.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)] flex flex-col gap-3 min-h-0 ops-lane-panel">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">선택한 Keeper 액션</h3>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${selectedKeeper ? html`
          <div class="flex flex-col gap-2">
            <div class="text-[13px] font-semibold text-[var(--text-strong)]">${selectedKeeper.name}</div>
            <div class="text-[11px] text-[var(--text-muted)] flex flex-wrap gap-2">
              <span>자율성: ${selectedKeeper.autonomy_level ?? '확인 없음'}</span>
              <span>세대: ${selectedKeeper.generation ?? 0}</span>
              <span>활성 목표: ${selectedKeeper.active_goal_ids?.length ?? 0}</span>
              ${typeof selectedKeeper.turn_count === 'number' ? html`<span>턴: ${selectedKeeper.turn_count}</span>` : null}
              ${selectedKeeper.last_model_used ? html`<span>모델: ${selectedKeeper.last_model_used}</span>` : null}
            </div>
            ${keeperPriorityTone(selectedKeeper) !== 'ok'
              ? html`<div class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-1">현재 점검 이유: ${keeperPrioritySummary(selectedKeeper)}</div>`
              : null}
            ${selectedKeeper.goal ? html`<div class="whitespace-normal mt-1.5 py-1 px-1.5 bg-[var(--white-3)] rounded text-[11px] text-[var(--text-muted)]">${selectedKeeper.goal}</div>` : null}
          </div>
          <${KeeperConversationPanel}
            keeperName=${selectedKeeper.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        ` : html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)] flex flex-col gap-3 min-h-0">
        <div class="flex items-center justify-between pb-2 border-b border-[var(--card-border)]">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">액션</h3>
          <span class="text-[12px] text-[var(--text-muted)]">${availableActions.length}개</span>
        </div>
        ${availableActions.length
          ? html`<div class="flex flex-col gap-2">
              ${['room', 'keeper', 'team_session'].map(targetType => {
                const group = availableActions.filter((a: any) => a.target_type === targetType)
                if (group.length === 0) return null
                return html`
                  <div key=${targetType}>
                    <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider mb-1">${targetTypeLabel(targetType)}</div>
                    <div class="flex flex-wrap gap-1">
                      ${group.map((action: any) => html`
                        <span key=${action.action_type}
                          title=${action.description ?? ''}
                          class="text-[12px] px-2 py-0.5 rounded cursor-default ${action.confirm_required ? 'bg-[var(--warn-12)] border border-[var(--warn-28)] text-[var(--warn)]' : 'bg-[var(--accent-8)] border border-[var(--accent-12)] text-[var(--accent)]'}">
                          ${actionTypeLabel(action.action_type)}
                        </span>
                      `)}
                    </div>
                  </div>
                `
              })}
            </div>`
          : html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">액션 없음</div>`}
      </section>

      <section class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)] flex flex-col gap-3 min-h-0">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">최근 개입 로그</h3>
        <div class="flex flex-col gap-2">
          ${operatorActionLog.value.length === 0 ? html`
            <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">이 세션에서 실행한 개입이 아직 없습니다.</div>
          ` : operatorActionLog.value.map(entry => html`
            <article key=${entry.id} class="py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded ${logEntryBorderClass(entry.outcome)}">
              <div class="text-[11px] text-[var(--text-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                <strong class="font-semibold">${actionTypeLabel(entry.action_type)}</strong>
                <span>${entry.target_label}</span>
                <span>${entry.at}</span>
              </div>
              <div class="mt-1 text-[13px] whitespace-pre-wrap break-words text-[var(--text-body)]">${entry.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `
}

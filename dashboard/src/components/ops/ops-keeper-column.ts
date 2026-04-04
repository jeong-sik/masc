// Ops — Keeper column: keeper list, keeper actions, available actions, recent action log

import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { openKeeperDetail } from '../keeper-detail'
import { findKeeper } from '../execution/shared'
import {
  operatorActionBusy,
  operatorActionLog,
  operatorSnapshot,
} from '../../operator-store'
import type { Keeper, OperatorKeeperSnapshot } from '../../types'
import {
  actionTypeLabel,
  displayStatus,
  keeperMessage,
  keeperPrioritySummary,
  keeperPriorityTone,
  relativeAge,
  selectedKeeperName,
  submitKeeperMessage,
  logEntryBorderClass,
} from './helpers'
import { truncate } from '../../lib/truncate'

function openOpsKeeperDetail(opsKeeper: OperatorKeeperSnapshot): void {
  const full = findKeeper(opsKeeper.name)
  const keeper: Keeper = full ?? {
    name: opsKeeper.name,
    agent_name: opsKeeper.agent_name ?? opsKeeper.name,
    status: opsKeeper.status ?? 'unknown',
    context_ratio: opsKeeper.context_ratio,
    model: opsKeeper.model,
  }
  openKeeperDetail(keeper)
}

export function OpsKeeperColumn() {
  const snapshot = operatorSnapshot.value
  const keepers = snapshot?.keepers ?? []
  const persistentAgents = snapshot?.persistent_agents ?? []
  const selectedKeeper = keepers.find(keeper => keeper.name === selectedKeeperName.value) ?? keepers[0] ?? null
  const busy = operatorActionBusy.value

  const statusCounts = keepers.reduce((acc: Record<string, number>, k) => {
    const s = k.status === 'active' || k.status === 'running' ? 'running'
      : k.status === 'offline' ? 'offline'
      : k.status === 'paused' ? 'paused'
      : k.status === 'crashed' ? 'crashed'
      : k.status === 'dead' ? 'dead'
      : 'other'
    acc[s] = (acc[s] ?? 0) + 1
    return acc
  }, {})

  return html`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0 ops-lane-panel ops-keeper-section">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">키퍼 목록</h3>
        ${keepers.length > 0 ? html`
          <div class="flex gap-3 text-[11px] font-mono">
            ${statusCounts.running ? html`<span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-[var(--ok)]"></span>${statusCounts.running} running</span>` : null}
            ${statusCounts.paused ? html`<span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-[#f59e0b]"></span>${statusCounts.paused} paused</span>` : null}
            ${statusCounts.crashed ? html`<span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-[#ef4444]"></span>${statusCounts.crashed} crashed</span>` : null}
            ${statusCounts.dead ? html`<span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-[#6b7280]"></span>${statusCounts.dead} dead</span>` : null}
            ${statusCounts.offline ? html`<span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-[var(--text-muted)]"></span>${statusCounts.offline} offline</span>` : null}
          </div>
        ` : null}
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">keeper를 선택하면 아래에서 메시지를 보내거나 상세 정보를 볼 수 있습니다.</p>

        <div class="flex flex-col gap-2">
          ${keepers.length === 0 ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">지금 보이는 keeper가 없습니다.</div>` : keepers.map(keeper => html`
            ${(() => {
              const tone = keeperPriorityTone(keeper)
              const prioritySummary = keeperPrioritySummary(keeper)
              return html`
            <button type="button"
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
                  <button type="button"
                    class="text-[11px] py-0.5 px-2 rounded-md border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--accent)] hover:bg-[var(--accent-20)] cursor-pointer transition-colors"
                    onClick=${(e: Event) => { e.stopPropagation(); openOpsKeeperDetail(keeper) }}
                  >상세 보기</button>
                </div>
              </div>
              <div class="text-[11px] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                <span>${keeper.last_model_used ?? keeper.model ?? 'model 확인 필요'}</span>
                <span>${typeof keeper.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}% ctx` : typeof keeper.context_tokens === 'number' ? `${Math.round(keeper.context_tokens / 1000)}k tok` : 'ctx 확인 필요'}</span>
                <span>${relativeAge(keeper.last_turn_ago_s)}</span>
              </div>
              ${keeper.short_goal || keeper.goal ? html`
                <div class="text-[11px] text-[var(--text-muted)] mt-1.5 p-1 px-1.5 bg-[var(--white-3)] rounded" title=${keeper.goal ?? ''}>${truncate(keeper.short_goal ?? keeper.goal ?? '', 60)}</div>
              ` : null}
              ${tone !== 'ok'
                ? html`<div class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-1.5">점검 이유: ${prioritySummary}</div>`
                : null}
              <div class="flex gap-2 text-[10px] text-[var(--text-muted)] mt-1">
                ${typeof keeper.turn_count === 'number' ? html`<span>turns: ${keeper.turn_count}</span>` : null}
                ${typeof keeper.autonomous_turn_count === 'number' ? html`<span>auto: ${keeper.autonomous_turn_count}</span>` : null}
                ${typeof keeper.autonomous_tool_turn_count === 'number' ? html`<span>tool: ${keeper.autonomous_tool_turn_count}</span>` : null}
                ${typeof keeper.autonomous_text_turn_count === 'number' ? html`<span>text: ${keeper.autonomous_text_turn_count}</span>` : null}
                ${keeper.keepalive_running ? html`<span class="text-[var(--ok)]">keepalive</span>` : null}
              </div>
            </button>
              `
            })()}
          `)}
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-3">Persistent agent alias는 같은 keeper 런타임을 호환 표기로 보여줍니다.</p>
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

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">선택한 Keeper 상태</h3>
        </div>
        ${selectedKeeper ? html`
          <article class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-2">
            <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
              <strong>${selectedKeeper.name}</strong>
              <span class="inline-flex items-center gap-1.5 text-[11px]">
                <span class="w-2 h-2 rounded-full ${selectedKeeper.status === 'offline' ? 'bg-[var(--text-muted)]' : selectedKeeper.status === 'active' || selectedKeeper.status === 'running' ? 'bg-[var(--ok)]' : 'bg-[var(--warn)]'}"></span>
                ${displayStatus(selectedKeeper.status)}
              </span>
            </div>
            <div class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
              ${keeperPrioritySummary(selectedKeeper)}
            </div>
            <div class="text-[11px] text-[var(--text-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
              <span>${selectedKeeper.last_model_used ?? selectedKeeper.model ?? 'model 확인 필요'}</span>
              <span>${typeof selectedKeeper.context_ratio === 'number' ? `${Math.round(selectedKeeper.context_ratio * 100)}% ctx` : typeof selectedKeeper.context_tokens === 'number' ? `${Math.round(selectedKeeper.context_tokens / 1000)}k tok` : 'ctx 확인 필요'}</span>
              <span>${relativeAge(selectedKeeper.last_turn_ago_s)}</span>
            </div>
          </article>

          <div class="grid gap-2 mt-1">
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="${selectedKeeper.name}에게 보낼 메시지"
              value=${keeperMessage.value}
              onInput=${(event: Event) => { keeperMessage.value = (event.target as HTMLTextAreaElement).value }}
              onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) void submitKeeperMessage() }}
              disabled=${busy}
            ></textarea>
            <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitKeeperMessage() }} disabled=${busy || !keeperMessage.value.trim()}>
              메시지 보내기
            <//>
          </div>
        ` : html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">키퍼를 선택하면 바로 메시지를 보낼 수 있습니다.</div>`}
      </section>

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0">
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

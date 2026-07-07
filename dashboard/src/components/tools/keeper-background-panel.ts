// Keeper autonomous background panel.
//
// Renders the one keeper-native autonomous surface no other panel exposes:
// per-keeper recurring tasks (data.keeper_background) with the owning keeper's
// loop liveness as context. The mockup's second group — async/deferred tool work
// (bg-shell / fusion / hitl) — is intentionally NOT rendered here; it is already
// shown by the adjacent KeeperWaitingInventoryPanel, so re-drawing it would
// duplicate that projection.

import { html } from 'htm/preact'
import type {
  DashboardKeeperBackground,
  DashboardKeeperBackgroundKeeper,
  DashboardKeeperRecurringTask,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, type StatusChipTone } from '../common/status-chip'

// Keeper lifecycle phase (Keeper_state_machine.n, lowercase wire form) → tone.
// Unknown phases render neutral rather than throwing.
function phaseTone(phase: string): StatusChipTone {
  switch (phase) {
    case 'running':
      return 'ok'
    case 'paused':
    case 'overflowed':
      return 'warn'
    case 'offline':
    case 'dead':
    case 'zombie':
      return 'bad'
    case 'restarting':
    case 'initializing':
      return 'info'
    default:
      return 'neutral'
  }
}

// interval_sec → a compact cadence label (매 6h / 매 30m / 매 45s). Whole units
// only collapse; anything else falls back to seconds.
function formatCadence(intervalSec: number): string {
  if (intervalSec > 0 && intervalSec % 86400 === 0) return `매 ${intervalSec / 86400}d`
  if (intervalSec > 0 && intervalSec % 3600 === 0) return `매 ${intervalSec / 3600}h`
  if (intervalSec > 0 && intervalSec % 60 === 0) return `매 ${intervalSec / 60}m`
  return `매 ${intervalSec}s`
}

function nextRunLabel(task: DashboardKeeperRecurringTask): string {
  if (task.next_run_at_iso) return `다음 ~${formatDateTimeKo(task.next_run_at_iso)}`
  // Honest absence: a paused or never-run task has no concrete next tick.
  return task.enabled ? '다음 tick 대기' : '멈춤 — 다음 없음'
}

function lastRunLabel(task: DashboardKeeperRecurringTask): string {
  if (task.last_run_at_iso) return `마지막 ${formatDateTimeKo(task.last_run_at_iso)}`
  return '실행 이력 없음'
}

function RecurringRow({ task }: { task: DashboardKeeperRecurringTask }) {
  const paused = !task.enabled
  return html`
    <li class="kbg-task" data-testid="kbg-task" data-task-id=${task.id}>
      <span class="kbg-task-cadence mono">↻ ${formatCadence(task.interval_sec)}</span>
      <span class="kbg-task-body">
        <span class="kbg-task-label">${task.label}</span>
        <span class="kbg-task-meta">
          <span class="mono kbg-task-kind">${task.action_kind}</span>
          <span class="mono kbg-task-runs">실행 ${task.run_count.toLocaleString()}${task.failure_count > 0 ? ` · 실패 ${task.failure_count.toLocaleString()}` : ''}</span>
          <span class="mono kbg-task-last">${lastRunLabel(task)}</span>
          <span class="mono kbg-task-next">${nextRunLabel(task)}</span>
        </span>
      </span>
      <${StatusChip} tone=${paused ? 'neutral' : 'ok'} uppercase=${false}>${paused ? '멈춤' : '활성'}<//>
    </li>
  `
}

function KeeperGroup({ keeper }: { keeper: DashboardKeeperBackgroundKeeper }) {
  const loop = keeper.loop
  const since = loop.started_at_iso ? `since ${formatDateTimeKo(loop.started_at_iso)}` : 'since 미상'
  return html`
    <section class="kbg-keeper" data-testid="kbg-keeper" data-keeper-name=${keeper.keeper_name}>
      <div class="kbg-keeper-h">
        <span class="kbg-keeper-name">${keeper.keeper_name}</span>
        <${StatusChip} tone=${phaseTone(loop.phase)} uppercase=${false}>${loop.phase}<//>
        <span class="mono kbg-keeper-since">${since}</span>
        ${loop.restart_count > 0
          ? html`<span class="mono kbg-keeper-restart" title="keeper 루프 재시작 횟수">restart ${loop.restart_count.toLocaleString()}</span>`
          : null}
        <span class="mono kbg-keeper-count">${keeper.recurring_count.toLocaleString()} 작업</span>
      </div>
      <ul class="kbg-tasks">
        ${keeper.recurring.map(task => html`<${RecurringRow} key=${task.id} task=${task} />`)}
      </ul>
    </section>
  `
}

export function KeeperBackgroundPanel({
  data,
}: {
  data: DashboardKeeperBackground | null | undefined
}) {
  const keepers = data?.keepers ?? []
  return html`
    <div class="kbg" data-testid="keeper-background-panel">
      <p class="kbg-sub">
        operator 승인 없이 keeper가 자기 turn에서 도는 주기 반복 작업 — 예약 큐와 별개 origin.
        비동기 대기(bg-shell · fusion · 승인)는 위 <span class="mono">Keeper Waiting Inventory</span>를 참조하세요.
      </p>
      ${keepers.length === 0
        ? html`<div class="kbg-empty mono" data-testid="keeper-background-empty">keeper 자율 반복 작업 없음</div>`
        : html`
            <div class="kbg-list">
              ${keepers.map(keeper => html`<${KeeperGroup} key=${keeper.keeper_name} keeper=${keeper} />`)}
            </div>
          `}
    </div>
  `
}

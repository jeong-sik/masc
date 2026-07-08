// Keeper autonomous background panel (server_keeper_background.dashboard_json).
//
// Renders per-keeper recurring tasks with the owning keeper's heartbeat-loop
// liveness as context. The backend projection only includes keepers that have
// at least one recurring task, so a keeper appearing here is, by construction,
// running autonomous recurring work — the loop row is the "is it alive" context
// for that work, not a standalone liveness board (fleet already carries that).
//
// Honesty contract (matches the projection's own rule): every field shown comes
// straight from the projection. `next`/`last` run times are `-` when the
// projection reports null (paused or never-run) — no ETA is fabricated, no
// bg-task is relabelled as a tool call.
import { html } from 'htm/preact'
import type {
  DashboardKeeperBackground,
  DashboardKeeperBackgroundKeeper,
  DashboardKeeperBackgroundLoop,
  DashboardKeeperRecurringTask,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, keeperStateTone } from '../common/status-chip'
import { enumLabel } from './keeper-waiting-inventory-panel'

function timeLabel(iso: string | null | undefined): string {
  if (!iso) return '-'
  return formatDateTimeKo(iso)
}

function CountPill({
  label,
  value,
}: {
  label: string
  value: number | string | null | undefined
}) {
  const displayValue =
    typeof value === 'number' ? value.toLocaleString() : value ?? 'unknown'
  return html`
    <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] bg-[var(--color-bg-hover)] px-2 py-1 text-2xs text-[var(--color-fg-secondary)]">
      <span>${label}</span>
      <span class="font-mono text-[var(--color-fg-primary)]">${displayValue}</span>
    </span>
  `
}

function LoopContext({ loop }: { loop: DashboardKeeperBackgroundLoop }) {
  return html`
    <div class="mt-1 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-2xs text-[var(--color-fg-muted)]">
      <span class="font-mono">restarts ${loop.restart_count.toLocaleString()}</span>
      <span aria-hidden="true">·</span>
      <span class="font-mono">since ${timeLabel(loop.started_at_iso)}</span>
      ${loop.dead_since_iso
        ? html`
            <span aria-hidden="true">·</span>
            <span class="font-mono text-[var(--color-status-warn)]">dead since ${timeLabel(loop.dead_since_iso)}</span>
          `
        : null}
    </div>
  `
}

function RecurringRow({ task }: { task: DashboardKeeperRecurringTask }) {
  const failClass =
    task.failure_count > 0 ? 'font-mono text-[var(--color-status-warn)]' : 'font-mono'
  return html`
    <div class="grid gap-1 border-t border-[var(--color-border-subtle)] py-2 first:border-t-0">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <${StatusChip} tone=${task.enabled ? 'ok' : 'paused'} uppercase=${false}>${task.enabled ? 'enabled' : 'disabled'}<//>
        <span class="min-w-0 truncate font-mono text-xs text-[var(--color-fg-primary)]">${task.label}</span>
        <span class="text-2xs text-[var(--color-fg-muted)]">${enumLabel(task.action_kind)}</span>
      </div>
      <div class="grid gap-1 text-2xs text-[var(--color-fg-muted)] sm:grid-cols-5">
        <span class="font-mono">every ${task.interval_sec.toLocaleString()}s</span>
        <span class="font-mono">runs ${task.run_count.toLocaleString()}</span>
        <span class=${failClass}>fail ${task.failure_count.toLocaleString()}/${task.max_failures.toLocaleString()}</span>
        <span>next ${timeLabel(task.next_run_at_iso)}</span>
        <span>last ${timeLabel(task.last_run_at_iso)}</span>
      </div>
    </div>
  `
}

function KeeperBackgroundCard({ keeper }: { keeper: DashboardKeeperBackgroundKeeper }) {
  const tasks = keeper.recurring ?? []
  return html`
    <article
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-testid="keeper-background-card"
      data-keeper-background=${keeper.keeper_name}
    >
      <div class="flex min-w-0 flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="min-w-0 truncate font-mono text-sm font-semibold text-[var(--color-fg-primary)]">${keeper.keeper_name}</span>
            <${StatusChip} tone=${keeperStateTone(keeper.loop.phase)} uppercase=${false}>${enumLabel(keeper.loop.phase)}<//>
          </div>
          <${LoopContext} loop=${keeper.loop} />
        </div>
        <span class="text-2xs text-[var(--color-fg-muted)]">
          <span class="font-mono text-[var(--color-fg-primary)]">${keeper.recurring_count.toLocaleString()}</span> recurring
        </span>
      </div>
      <div class="mt-2">
        ${tasks.length > 0
          ? tasks.map(task => html`<${RecurringRow} key=${task.id} task=${task} />`)
          : html`<div class="border-t border-[var(--color-border-subtle)] pt-2 text-xs text-[var(--color-fg-muted)]">no recurring tasks</div>`}
      </div>
    </article>
  `
}

export function KeeperBackgroundPanel({
  background,
}: {
  background: DashboardKeeperBackground | null | undefined
}) {
  if (!background) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">keeper background unavailable</div>`
  }
  const keepers = background.keepers ?? []
  return html`
    <div class="grid gap-3" data-testid="keeper-background-inventory">
      <div class="flex flex-wrap gap-1.5">
        <${CountPill} label="keepers" value=${background.keeper_count} />
        <${CountPill} label="recurring keepers" value=${background.recurring_keeper_count} />
        <${CountPill} label="recurring tasks" value=${background.recurring_count} />
      </div>
      ${keepers.length > 0
        ? html`<div class="grid gap-2 lg:grid-cols-2">${keepers.map(keeper => html`<${KeeperBackgroundCard} key=${keeper.keeper_name} keeper=${keeper} />`)}</div>`
        : html`<div class="text-xs text-[var(--color-fg-muted)]">no keeper background loops in projection</div>`}
    </div>
  `
}

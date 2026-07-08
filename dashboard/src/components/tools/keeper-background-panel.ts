// Keeper autonomous background panel (server_keeper_background.dashboard_json).
//
// Renders per-keeper recurring tasks with the owning keeper's heartbeat-loop
// liveness as context. The backend projection only includes keepers that have
// at least one recurring task, so a keeper appearing here is, by construction,
// running autonomous recurring work — the loop row is the "is it alive" context
// for that work, not a standalone liveness board (fleet already carries that).
//
// Presentation follows the keeper-v2 schedule skin (`.sch-bg-*` in
// styles/keeper-v2/schedule.css): a two-column grid where each grid cell is one
// keeper group (grp header + recurring-task rows), matching the sibling
// `.sch-ev` row convention (left tone stripe, body, meta, status chip).
//
// Honesty contract (matches the projection's own rule): every field shown comes
// straight from the projection. `next`/`last` run times are `-` when the
// projection reports null (paused or never-run) — no ETA is fabricated, no
// bg-task is relabelled as a tool call. The loop's restart/dead-since context is
// kept visible even though the mockup's group header was cosmetic-only.
import { html } from 'htm/preact'
import type {
  DashboardKeeperBackground,
  DashboardKeeperBackgroundKeeper,
  DashboardKeeperBackgroundLoop,
  DashboardKeeperRecurringTask,
} from '../../api'
import {
  SECONDS_PER_HOUR,
  SECONDS_PER_MINUTE,
  formatTimeAgo,
  formatTimeUntil,
} from '../../lib/format-time'
import { StatusChip, keeperStateTone } from '../common/status-chip'
import { enumLabel } from './keeper-waiting-inventory-panel'

// Compact fire cadence for the fixed-width `when` column. Interval is always
// present (unlike next-run, which is null while paused/never-run), so this
// column never renders a fabricated or empty time.
function cadenceLabel(intervalSec: number): string {
  if (intervalSec < SECONDS_PER_MINUTE) return `${intervalSec}s`
  if (intervalSec < SECONDS_PER_HOUR)
    return `${Math.round(intervalSec / SECONDS_PER_MINUTE)}m`
  return `${Math.round(intervalSec / SECONDS_PER_HOUR)}h`
}

// Row tone stripe (st-ok/st-warn/st-dim) derived from numeric/boolean state, not
// a string classifier: disabled → dim, any consecutive failures → warn, else ok.
function rowToneClass(task: DashboardKeeperRecurringTask): string {
  if (!task.enabled) return 'st-dim'
  if (task.failure_count > 0) return 'st-warn'
  return 'st-ok'
}

function LoopContext({ loop }: { loop: DashboardKeeperBackgroundLoop }) {
  return html`
    <div class="sch-bg-grp-ctx">
      <span class="font-mono">restarts ${loop.restart_count.toLocaleString()}</span>
      <span aria-hidden="true">·</span>
      <span class="font-mono">since ${loop.started_at_iso ? formatTimeAgo(loop.started_at_iso) : '-'}</span>
      ${loop.dead_since_iso
        ? html`
            <span aria-hidden="true">·</span>
            <span class="font-mono sch-bg-grp-dead">dead since ${formatTimeAgo(loop.dead_since_iso)}</span>
          `
        : null}
    </div>
  `
}

function RecurringRow({ task }: { task: DashboardKeeperRecurringTask }) {
  return html`
    <div class="sch-bg-row ${rowToneClass(task)}">
      <div class="sch-bg-when">${cadenceLabel(task.interval_sec)}</div>
      <div class="sch-bg-body">
        <div class="sch-bg-title">${task.label}</div>
        <div class="sch-bg-meta">
          <span class="sch-bg-by">${enumLabel(task.action_kind)}</span>
          <span class="sch-bg-since font-mono">every ${task.interval_sec.toLocaleString()}s</span>
          <span class="sch-bg-since font-mono">runs ${task.run_count.toLocaleString()}</span>
          <span class="sch-bg-since font-mono">fail ${task.failure_count.toLocaleString()}/${task.max_failures.toLocaleString()}</span>
          <span class="sch-bg-since">next ${task.next_run_at_iso ? formatTimeUntil(task.next_run_at_iso) : '-'}</span>
          <span class="sch-bg-since">last ${task.last_run_at_iso ? formatTimeAgo(task.last_run_at_iso) : '-'}</span>
        </div>
      </div>
      <${StatusChip} tone=${task.enabled ? 'ok' : 'paused'} uppercase=${false}>${task.enabled ? 'enabled' : 'disabled'}<//>
    </div>
  `
}

function KeeperBackgroundGroup({ keeper }: { keeper: DashboardKeeperBackgroundKeeper }) {
  const tasks = keeper.recurring ?? []
  return html`
    <div
      class="sch-bg-grp"
      data-testid="keeper-background-card"
      data-keeper-background=${keeper.keeper_name}
    >
      <div class="sch-bg-grp-h">
        <span class="sch-bg-grp-n font-mono">${keeper.keeper_name}</span>
        <${StatusChip} tone=${keeperStateTone(keeper.loop.phase)} uppercase=${false}>${enumLabel(keeper.loop.phase)}<//>
        <span class="sch-bg-since font-mono">${keeper.recurring_count.toLocaleString()} recurring</span>
        <${LoopContext} loop=${keeper.loop} />
      </div>
      <div class="sch-bg-list">
        ${tasks.length > 0
          ? tasks.map(task => html`<${RecurringRow} key=${task.id} task=${task} />`)
          : html`<div class="sch-bg-empty">no recurring tasks</div>`}
      </div>
    </div>
  `
}

export function KeeperBackgroundPanel({
  background,
}: {
  background: DashboardKeeperBackground | null | undefined
}) {
  if (!background) {
    return html`<div class="sch-bg-empty">keeper background unavailable</div>`
  }
  const keepers = background.keepers ?? []
  return html`
    <section class="sch-bg" data-testid="keeper-background-inventory">
      <div class="sch-bg-h">
        <h3>Keeper 자율 백그라운드</h3>
        <div class="sch-bg-sub">
          <span class="font-mono">keepers ${background.keeper_count.toLocaleString()}</span>
          <span class="font-mono">recurring keepers ${background.recurring_keeper_count.toLocaleString()}</span>
          <span class="font-mono">recurring tasks ${background.recurring_count.toLocaleString()}</span>
        </div>
      </div>
      ${keepers.length > 0
        ? html`<div class="sch-bg-grps">${keepers.map(keeper => html`<${KeeperBackgroundGroup} key=${keeper.keeper_name} keeper=${keeper} />`)}</div>`
        : html`<div class="sch-bg-empty">no keeper background loops in projection</div>`}
    </section>
  `
}

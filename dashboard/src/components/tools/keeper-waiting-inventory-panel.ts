import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingRow,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import {
  LaneAgeAxis,
  LaneWaitingRow,
  ageMinutes,
  DAY_MINUTES,
  waitingRowsOldestFirst,
} from '../keeper-workspace/keeper-lane-strip'

// Exported for the keeper workspace lane strip (#23507): the lane
// state/source palettes stay single-sourced here instead of growing a
// second copy per consuming surface.
export function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

export function stateTone(state: string | null | undefined): StatusChipTone {
  switch (state) {
    case 'waiting':
      return 'warn'
    case 'deferred':
      return 'info'
    case 'busy':
      return 'ok'
    case 'idle':
      return 'neutral'
    default:
      return 'neutral'
  }
}

export function sourceTone(source: string | null | undefined): StatusChipTone {
  switch (source) {
    case 'read_error':
      return 'bad'
    case 'hitl_pending':
    case 'operator_pending_confirm':
    case 'schedule_waiting':
    case 'chat_operation_queued':
      return 'warn'
    case 'fusion_running':
    case 'chat_operation_running':
    case 'owner_shutdown':
      return 'info'
    default:
      return 'neutral'
  }
}

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

function SourceCounts({ counts }: { counts: Record<string, number> | null | undefined }) {
  const entries = Object.entries(counts ?? {})
    .filter(([, count]) => count > 0)
    .sort(([left], [right]) => left.localeCompare(right))
    .slice(0, 8)
  if (entries.length === 0) return null
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${entries.map(([source, count]) => html`<${CountPill} key=${source} label=${enumLabel(source)} value=${count} />`)}
    </div>
  `
}

/** The shared V2 waiting-row block (#29473): rows oldest first on a log age
 *  axis, each row the server's operator sentence (`what`) with the raw wire
 *  vocabulary behind the 기술 상세 toggle. Reused by the keeper workspace
 *  lane strip and the fleet surfaces so both draw the same row component.
 *  No client-side cap: the server's own truncation flag is the only bound. */
function LaneRows({ rows, dev }: { rows: DashboardKeeperWaitingRow[]; dev: boolean }) {
  const sorted = waitingRowsOldestFirst(rows)
  const nowMs = Date.now()
  const ages = sorted.map(row => ageMinutes(row, nowMs))
  const axisMax = Math.max(DAY_MINUTES, ...ages.filter((age): age is number => age != null))
  if (sorted.length === 0) return null
  return html`
    <div class="grid gap-1">
      <div class="font-mono text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">오래 기다린 순서</div>
      <${LaneAgeAxis} axisMax=${axisMax} />
      <div class="grid max-h-[30rem] gap-1 overflow-y-auto pr-1" data-testid="keeper-lane-graph" aria-label="대기 나이순 작업 흐름">
        ${sorted.map((row, index) => html`
          <${LaneWaitingRow}
            key=${`${row.source}:${row.waiting_on}:${index}`}
            row=${row}
            age=${ages[index] ?? null}
            axisMax=${axisMax}
            dev=${dev}
            actions=${null}
          />
        `)}
      </div>
    </div>
  `
}

function KeeperRow({ keeper, dev }: { keeper: DashboardKeeperWaitingKeeper; dev: boolean }) {
  const rows = keeper.waiting_on ?? []
  const waitingCount = keeper.waiting_count ?? 0
  return html`
    <div class="border-t border-[var(--color-border-subtle)] py-3 first:border-t-0" data-keeper-lane=${keeper.keeper_name}>
      <div class="mb-2 flex min-w-0 flex-wrap items-center justify-between gap-2">
        <div class="flex min-w-0 items-center gap-2">
          <span class="min-w-0 truncate font-mono text-sm text-[var(--color-fg-primary)]">${keeper.keeper_name}</span>
          <${StatusChip} tone=${stateTone(keeper.state)} uppercase=${false}>${enumLabel(keeper.state)}<//>
        </div>
        <span class="text-2xs text-[var(--color-fg-muted)]">${waitingCount} rows</span>
      </div>
      <${SourceCounts} counts=${keeper.sources} />
      <div class="mt-2">
        <${LaneRows} rows=${rows} dev=${dev} />
      </div>
    </div>
  `
}

function keeperVisible(keeper: DashboardKeeperWaitingKeeper): boolean {
  return keeper.waiting_count > 0 || keeper.state !== 'idle'
}

export function KeeperWaitingInventoryPanel({
  inventory,
}: {
  inventory: DashboardKeeperWaitingInventory | null | undefined
}) {
  const [dev, setDev] = useState(false)
  if (!inventory) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">waiting inventory unavailable</div>`
  }
  const activeKeepers = (inventory.keepers ?? []).filter(keeperVisible)
  const globalRows = inventory.global_waiting_on ?? []
  const keeperCount =
    inventory.keeper_count_known === false ? 'unknown' : inventory.keeper_count
  const pendingConfirmCount =
    inventory.global_pending_confirm_count_known === false
      ? 'unknown'
      : inventory.global_pending_confirm_count ?? 0
  return html`
    <div class="grid gap-3">
      <div class="flex flex-wrap gap-1.5">
        <${CountPill} label="keepers" value=${keeperCount} />
        <${CountPill} label="waiting" value=${inventory.waiting_keeper_count} />
        <${CountPill} label="rows" value=${inventory.row_count} />
        <${CountPill} label="global" value=${inventory.global_row_count ?? 0} />
        <${CountPill} label="unmapped confirms" value=${pendingConfirmCount} />
        <button
          type="button"
          class=${`ml-auto rounded-[var(--r-0)] border px-1.5 py-0.5 text-3xs font-normal ${dev ? 'border-[var(--color-accent)] text-[var(--color-accent-fg)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
          aria-pressed=${dev}
          title="내부 식별자 · 원본 필드 표시"
          data-testid="keeper-lane-dev-toggle"
          onClick=${() => setDev(current => !current)}
        >기술 상세</button>
      </div>
      <${SourceCounts} counts=${inventory.source_counts} />
      ${activeKeepers.length > 0
        ? html`<div>${activeKeepers.map(keeper => html`<${KeeperRow} key=${keeper.keeper_name} keeper=${keeper} dev=${dev} />`)}</div>`
        : html`<div class="text-xs text-[var(--color-fg-muted)]">no keeper-specific waiting rows</div>`}
      ${globalRows.length > 0
        ? html`
            <div class="border-t border-[var(--color-border-subtle)] pt-3">
              <div class="mb-1 text-xs font-medium text-[var(--color-fg-secondary)]">Global waiting</div>
              <${LaneRows} rows=${globalRows} dev=${dev} />
            </div>
          `
        : null}
    </div>
  `
}

function laneSummary(keeper: DashboardKeeperWaitingKeeper): string {
  const sourceActions = Object.entries(keeper.source_next_actions ?? {})
    .flatMap(([source, actions]) => actions.map(action => `${enumLabel(source)}: ${enumLabel(action)}`))
  // No aggregate fallback: the producer emits source_next_actions and has never
  // emitted a keeper-level next_action, so reading one only ever produced the
  // same "unavailable" label by a longer route (#27750).
  const actionSummary = sourceActions.length > 0
    ? sourceActions.join(', ')
    : 'source actions unavailable'
  const dueAt = timeLabel(keeper.due_at_iso)
  const since = timeLabel(keeper.since_iso)
  return [
    `state ${enumLabel(keeper.state)}`,
    `waiting ${keeper.waiting_count.toLocaleString()}`,
    `since ${since}`,
    `due ${dueAt}`,
    actionSummary,
  ].join(' · ')
}

function LaneEvidenceCard({ keeper, dev }: { keeper: DashboardKeeperWaitingKeeper; dev: boolean }) {
  const rows = keeper.waiting_on ?? []
  const waitingCount = keeper.waiting_count ?? 0
  return html`
    <article
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-testid="keeper-lane-card"
      data-keeper-lane=${keeper.keeper_name}
    >
      <div class="flex min-w-0 flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="min-w-0 truncate font-mono text-sm font-semibold text-[var(--color-fg-primary)]">${keeper.keeper_name}</span>
            <${StatusChip} tone=${stateTone(keeper.state)} uppercase=${false}>${enumLabel(keeper.state)}<//>
          </div>
          <div class="mt-1 text-2xs text-[var(--color-fg-muted)]" title=${laneSummary(keeper)}>
            <span class="font-mono">since ${timeLabel(keeper.since_iso)}</span>
            <span aria-hidden="true"> · </span>
            <span class="font-mono">due ${timeLabel(keeper.due_at_iso)}</span>
          </div>
        </div>
        <div class="text-right text-2xs text-[var(--color-fg-muted)]">
          <div><span class="font-mono text-[var(--color-fg-primary)]">${waitingCount}</span> lane rows</div>
          ${Object.keys(keeper.source_next_actions ?? {}).length > 0
            ? html`<div class="font-mono">source별 next action</div>`
            : html`<div class="font-mono text-[var(--color-status-warn)]">source actions unavailable</div>`}
        </div>
      </div>
      <div class="mt-2">
        <${SourceCounts} counts=${keeper.sources} />
      </div>
      <div class="mt-2">
        ${rows.length > 0
          ? html`<${LaneRows} rows=${rows} dev=${dev} />`
          : html`<div class="border-t border-[var(--color-border-subtle)] pt-2 text-xs text-[var(--color-fg-muted)]">no keeper-specific waiting rows</div>`}
      </div>
    </article>
  `
}

export function KeeperLaneInventoryPanel({
  inventory,
}: {
  inventory: DashboardKeeperWaitingInventory | null | undefined
}) {
  const [dev, setDev] = useState(false)
  if (!inventory) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">keeper lane evidence unavailable</div>`
  }
  const lanes = inventory.keepers ?? []
  const globalRows = inventory.global_waiting_on ?? []
  const keeperCount =
    inventory.keeper_count_known === false ? 'unknown' : inventory.keeper_count
  const pendingConfirmCount =
    inventory.global_pending_confirm_count_known === false
      ? 'unknown'
      : inventory.global_pending_confirm_count ?? 0
  return html`
    <div class="grid gap-3" data-testid="keeper-lane-inventory">
      <div class="flex flex-wrap gap-1.5">
        <${CountPill} label="keeper lanes" value=${keeperCount} />
        <${CountPill} label="waiting lanes" value=${inventory.waiting_keeper_count} />
        <${CountPill} label="lane rows" value=${inventory.row_count} />
        <${CountPill} label="global rows" value=${inventory.global_row_count ?? 0} />
        <${CountPill} label="unmapped confirms" value=${pendingConfirmCount} />
        <button
          type="button"
          class=${`ml-auto rounded-[var(--r-0)] border px-1.5 py-0.5 text-3xs font-normal ${dev ? 'border-[var(--color-accent)] text-[var(--color-accent-fg)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
          aria-pressed=${dev}
          title="내부 식별자 · 원본 필드 표시"
          data-testid="keeper-lane-dev-toggle"
          onClick=${() => setDev(current => !current)}
        >기술 상세</button>
      </div>
      <${SourceCounts} counts=${inventory.source_counts} />
      ${lanes.length > 0
        ? html`<div class="grid gap-2 lg:grid-cols-2">${lanes.map(keeper => html`<${LaneEvidenceCard} key=${keeper.keeper_name} keeper=${keeper} dev=${dev} />`)}</div>`
        : html`<div class="text-xs text-[var(--color-fg-muted)]">no keeper lane rows in projection</div>`}
      ${globalRows.length > 0
        ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
              <div class="mb-1 text-xs font-medium text-[var(--color-fg-secondary)]">Global lane evidence</div>
              <${LaneRows} rows=${globalRows} dev=${dev} />
            </div>
          `
        : null}
    </div>
  `
}

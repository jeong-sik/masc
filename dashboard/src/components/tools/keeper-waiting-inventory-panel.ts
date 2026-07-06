import { html } from 'htm/preact'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingRow,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, type StatusChipTone } from '../common/status-chip'

function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

function stateTone(state: string | null | undefined): StatusChipTone {
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

function sourceTone(source: string | null | undefined): StatusChipTone {
  switch (source) {
    case 'read_error':
      return 'bad'
    case 'hitl_pending':
    case 'operator_pending_confirm':
    case 'schedule_waiting':
    case 'turn_admission_waiting':
      return 'warn'
    case 'fusion_running':
    case 'background_task':
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

function WaitingRow({ row }: { row: DashboardKeeperWaitingRow }) {
  return html`
    <div class="grid gap-1 border-t border-[var(--color-border-subtle)] py-2 first:border-t-0">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <${StatusChip} tone=${sourceTone(row.source)} uppercase=${false}>${enumLabel(row.source)}<//>
        <span class="min-w-0 truncate font-mono text-xs text-[var(--color-fg-primary)]">${row.waiting_on}</span>
      </div>
      <div class="grid gap-1 text-2xs text-[var(--color-fg-muted)] sm:grid-cols-4">
        <span>since ${timeLabel(row.since_iso)}</span>
        <span>due ${timeLabel(row.due_at_iso)}</span>
        <span class="font-mono">producer ${enumLabel(row.wake_producer)}</span>
        <span class="font-mono">${enumLabel(row.next_action)}</span>
      </div>
    </div>
  `
}

function KeeperRow({ keeper }: { keeper: DashboardKeeperWaitingKeeper }) {
  const rows = (keeper.waiting_on ?? []).slice(0, 4)
  const truncatedSources = Object.entries(keeper.truncated_sources ?? {})
    .filter(([, truncated]) => truncated)
    .map(([source]) => enumLabel(source))
  return html`
    <div class="border-t border-[var(--color-border-subtle)] py-3 first:border-t-0">
      <div class="mb-2 flex min-w-0 flex-wrap items-center justify-between gap-2">
        <div class="flex min-w-0 items-center gap-2">
          <span class="min-w-0 truncate font-mono text-sm text-[var(--color-fg-primary)]">${keeper.keeper_name}</span>
          <${StatusChip} tone=${stateTone(keeper.state)} uppercase=${false}>${enumLabel(keeper.state)}<//>
        </div>
        <span class="text-2xs text-[var(--color-fg-muted)]">${keeper.waiting_count.toLocaleString()} rows</span>
      </div>
      <${SourceCounts} counts=${keeper.sources} />
      ${keeper.waiting_count_truncated
        ? html`
            <div class="mt-2 text-2xs text-[var(--color-status-warn)]">
              truncated ${truncatedSources.length > 0 ? truncatedSources.join(', ') : 'waiting rows'}
            </div>
          `
        : null}
      <div class="mt-2">
        ${rows.map((row, index) => html`<${WaitingRow} key=${`${row.source}:${row.waiting_on}:${index}`} row=${row} />`)}
        ${keeper.waiting_count > rows.length
          ? html`<div class="pt-1 text-2xs text-[var(--color-fg-muted)]">+${keeper.waiting_count - rows.length} more</div>`
          : null}
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
  if (!inventory) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">waiting inventory unavailable</div>`
  }
  const activeKeepers = (inventory.keepers ?? [])
    .filter(keeperVisible)
    .slice(0, 8)
  const globalRows = (inventory.global_waiting_on ?? []).slice(0, 4)
  const keeperCount =
    inventory.keeper_count_known === false ? 'unknown' : inventory.keeper_count
  const pendingConfirmCount =
    inventory.global_pending_confirm_count_known === false
      ? 'unknown'
      : inventory.global_pending_confirm_count ?? 0
  const truncatedKeeperCount = inventory.external_attention_truncated_keeper_count ?? 0
  return html`
    <div class="grid gap-3">
      <div class="flex flex-wrap gap-1.5">
        <${CountPill} label="keepers" value=${keeperCount} />
        <${CountPill} label="waiting" value=${inventory.waiting_keeper_count} />
        <${CountPill} label="rows" value=${inventory.row_count} />
        <${CountPill} label="global" value=${inventory.global_row_count ?? 0} />
        <${CountPill} label="unmapped confirms" value=${pendingConfirmCount} />
        ${inventory.row_count_truncated
          ? html`<${CountPill} label="truncated keepers" value=${truncatedKeeperCount} />`
          : null}
      </div>
      <${SourceCounts} counts=${inventory.source_counts} />
      ${activeKeepers.length > 0
        ? html`<div>${activeKeepers.map(keeper => html`<${KeeperRow} key=${keeper.keeper_name} keeper=${keeper} />`)}</div>`
        : html`<div class="text-xs text-[var(--color-fg-muted)]">no keeper-specific waiting rows</div>`}
      ${globalRows.length > 0
        ? html`
            <div class="border-t border-[var(--color-border-subtle)] pt-3">
              <div class="mb-1 text-xs font-medium text-[var(--color-fg-secondary)]">Global waiting</div>
              ${globalRows.map((row, index) => html`<${WaitingRow} key=${`${row.source}:${row.waiting_on}:${index}`} row=${row} />`)}
            </div>
          `
        : null}
    </div>
  `
}

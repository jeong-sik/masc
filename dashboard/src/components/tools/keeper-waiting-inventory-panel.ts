import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingRow,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, type StatusChipTone } from '../common/status-chip'

// Exported for the keeper workspace lane strip (#23507): the lane
// state/source palettes stay single-sourced here instead of growing a
// second copy per consuming surface.
export function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

function evidenceLabel(value: string | null | undefined, missingLabel: string): string {
  if (!value) return missingLabel
  const trimmed = value.trim()
  return trimmed ? enumLabel(trimmed) : missingLabel
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
    case 'chat_queue_recovery_required':
    case 'chat_queue_persistence_blocked':
      return 'bad'
    case 'hitl_pending':
    case 'operator_pending_confirm':
    case 'schedule_waiting':
    case 'turn_admission_waiting':
      return 'warn'
    case 'fusion_running':
    case 'background_task':
    case 'turn_admission_shutdown':
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

function asDetailRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function WaitingRowReceiptDetail({ row }: { row: DashboardKeeperWaitingRow }) {
  const detail = asDetailRecord(row.detail)
  const lifecycle = asDetailRecord(detail?.lifecycle)
  const receiptId = typeof detail?.receipt_id === 'string' ? detail.receipt_id : null
  if (!receiptId) return null
  const queueIndex = typeof detail?.queue_index === 'number' ? detail.queue_index : null
  const state = typeof lifecycle?.state === 'string' ? lifecycle.state : null
  const leaseId = typeof lifecycle?.lease_id === 'string' ? lifecycle.lease_id : null
  const startedAt = typeof lifecycle?.started_at_iso === 'string'
    ? lifecycle.started_at_iso
    : null
  return html`
    <div
      class="flex min-w-0 flex-wrap gap-x-3 gap-y-1 text-2xs text-[var(--color-fg-muted)]"
      data-keeper-chat-receipt=${receiptId}
    >
      <span class="min-w-0 break-all font-mono">receipt ${receiptId}</span>
      ${queueIndex === null ? null : html`<span class="font-mono">queue index ${queueIndex}</span>`}
      ${state ? html`<span class="font-mono">state ${enumLabel(state)}</span>` : null}
      ${leaseId ? html`<span class="min-w-0 break-all font-mono">lease ${leaseId}</span>` : null}
      ${startedAt ? html`<span>started ${timeLabel(startedAt)}</span>` : null}
    </div>
  `
}

function WaitingRowShutdownDetail({ row }: { row: DashboardKeeperWaitingRow }) {
  if (row.source !== 'turn_admission_shutdown') return null
  const detail = asDetailRecord(row.detail)
  const operationId = typeof detail?.shutdown_operation_id === 'string'
    ? detail.shutdown_operation_id.trim()
    : ''
  if (!operationId) return null
  const admissionFenced = detail?.admission_fenced === true
  return html`
    <div
      class="flex min-w-0 flex-wrap gap-x-3 gap-y-1 text-2xs text-[var(--color-fg-muted)]"
      data-keeper-shutdown-operation-id=${operationId}
    >
      <span class="min-w-0 break-all font-mono">shutdown operation ${operationId}</span>
      ${admissionFenced ? html`<span>admission fenced</span>` : null}
    </div>
  `
}

function WaitingRow({ row }: { row: DashboardKeeperWaitingRow }) {
  const wakeProducer = evidenceLabel(row.wake_producer, 'wake producer missing')
  const nextAction = evidenceLabel(row.next_action, 'next action missing')
  return html`
    <div class="grid gap-1 border-t border-[var(--color-border-subtle)] py-2 first:border-t-0">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <${StatusChip} tone=${sourceTone(row.source)} uppercase=${false}>${enumLabel(row.source)}<//>
        <span class="min-w-0 truncate font-mono text-xs text-[var(--color-fg-primary)]">${row.waiting_on}</span>
      </div>
      <div class="grid gap-1 text-2xs text-[var(--color-fg-muted)] sm:grid-cols-4">
        <span>since ${timeLabel(row.since_iso)}</span>
        <span>due ${timeLabel(row.due_at_iso)}</span>
        <span class="font-mono">producer ${wakeProducer}</span>
        <span class="font-mono">${nextAction}</span>
      </div>
      <${WaitingRowReceiptDetail} row=${row} />
      <${WaitingRowShutdownDetail} row=${row} />
    </div>
  `
}

function KeeperRow({ keeper }: { keeper: DashboardKeeperWaitingKeeper }) {
  const [expanded, setExpanded] = useState(false)
  const allRows = keeper.waiting_on ?? []
  const rows = expanded ? allRows : allRows.slice(0, 4)
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
        ${allRows.length > rows.length
          ? html`<button type="button" class="pt-1 text-2xs font-medium text-[var(--color-accent-fg)]" onClick=${() => setExpanded(true)} data-expand-waiting-rows>+${allRows.length - rows.length} more · 전체 보기</button>`
          : expanded && allRows.length > 4
            ? html`<button type="button" class="pt-1 text-2xs font-medium text-[var(--color-accent-fg)]" onClick=${() => setExpanded(false)} data-collapse-waiting-rows>접기</button>`
          : null}
        ${keeper.waiting_count > allRows.length
          ? html`<div class="pt-1 text-2xs text-[var(--color-status-warn)]">서버 projection에서 ${keeper.waiting_count - allRows.length}행이 추가로 생략되었습니다.</div>`
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

function laneSummary(keeper: DashboardKeeperWaitingKeeper): string {
  const nextAction = evidenceLabel(keeper.next_action, 'next action unavailable')
  const dueAt = timeLabel(keeper.due_at_iso)
  const since = timeLabel(keeper.since_iso)
  return [
    `state ${enumLabel(keeper.state)}`,
    `waiting ${keeper.waiting_count.toLocaleString()}`,
    `since ${since}`,
    `due ${dueAt}`,
    nextAction,
  ].join(' · ')
}

function LaneEvidenceCard({ keeper }: { keeper: DashboardKeeperWaitingKeeper }) {
  const [expanded, setExpanded] = useState(false)
  const allRows = keeper.waiting_on ?? []
  const rows = expanded ? allRows : allRows.slice(0, 6)
  const truncatedSources = Object.entries(keeper.truncated_sources ?? {})
    .filter(([, truncated]) => truncated)
    .map(([source]) => enumLabel(source))
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
          <div><span class="font-mono text-[var(--color-fg-primary)]">${keeper.waiting_count.toLocaleString()}</span> lane rows</div>
          ${keeper.next_action
            ? html`<div class="font-mono">${enumLabel(keeper.next_action)}</div>`
            : html`<div class="font-mono text-[var(--color-status-warn)]">next action unavailable</div>`}
        </div>
      </div>
      <div class="mt-2">
        <${SourceCounts} counts=${keeper.sources} />
      </div>
      ${keeper.waiting_count_truncated
        ? html`
            <div class="mt-2 text-2xs text-[var(--color-status-warn)]">
              truncated ${truncatedSources.length > 0 ? truncatedSources.join(', ') : 'waiting rows'}
            </div>
          `
        : null}
      <div class="mt-2">
        ${rows.length > 0
          ? rows.map((row, index) => html`<${WaitingRow} key=${`${row.source}:${row.waiting_on}:${index}`} row=${row} />`)
          : html`<div class="border-t border-[var(--color-border-subtle)] pt-2 text-xs text-[var(--color-fg-muted)]">no keeper-specific waiting rows</div>`}
        ${allRows.length > rows.length
          ? html`<button type="button" class="pt-1 text-2xs font-medium text-[var(--color-accent-fg)]" onClick=${() => setExpanded(true)} data-expand-lane-rows>+${allRows.length - rows.length} more · 전체 보기</button>`
          : expanded && allRows.length > 6
            ? html`<button type="button" class="pt-1 text-2xs font-medium text-[var(--color-accent-fg)]" onClick=${() => setExpanded(false)} data-collapse-lane-rows>접기</button>`
          : null}
        ${keeper.waiting_count > allRows.length
          ? html`<div class="pt-1 text-2xs text-[var(--color-status-warn)]">서버 projection에서 ${keeper.waiting_count - allRows.length}행이 추가로 생략되었습니다.</div>`
          : null}
      </div>
    </article>
  `
}

export function KeeperLaneInventoryPanel({
  inventory,
}: {
  inventory: DashboardKeeperWaitingInventory | null | undefined
}) {
  if (!inventory) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">keeper lane evidence unavailable</div>`
  }
  const lanes = inventory.keepers ?? []
  const globalRows = (inventory.global_waiting_on ?? []).slice(0, 6)
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
      </div>
      <${SourceCounts} counts=${inventory.source_counts} />
      ${lanes.length > 0
        ? html`<div class="grid gap-2 lg:grid-cols-2">${lanes.map(keeper => html`<${LaneEvidenceCard} key=${keeper.keeper_name} keeper=${keeper} />`)}</div>`
        : html`<div class="text-xs text-[var(--color-fg-muted)]">no keeper lane rows in projection</div>`}
      ${inventory.row_count_truncated
        ? html`
            <div class="text-2xs text-[var(--color-status-warn)]">
              lane projection truncated at ${inventory.external_attention_row_limit ?? 'unknown'} rows
            </div>
          `
        : null}
      ${globalRows.length > 0
        ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
              <div class="mb-1 text-xs font-medium text-[var(--color-fg-secondary)]">Global lane evidence</div>
              ${globalRows.map((row, index) => html`<${WaitingRow} key=${`${row.source}:${row.waiting_on}:${index}`} row=${row} />`)}
            </div>
          `
        : null}
    </div>
  `
}

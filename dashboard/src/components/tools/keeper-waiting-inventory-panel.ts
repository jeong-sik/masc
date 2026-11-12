import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { LaneWaitingRows } from '../keeper-workspace/keeper-lane-strip'

// Exported for the keeper workspace lane strip (#23507): the lane
// state/source palettes stay single-sourced here instead of growing a
// second copy per consuming surface.
export function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

/** A Keeper waiting state as the server words it, in capitals: IDLE, BUSY,
 *  WAITING, DEFERRED. Every surface shows this one word for the state. */
export function waitingStateLabel(state: string | null | undefined): string {
  if (!state) return '-'
  return state.toUpperCase()
}

/** The state with what put the Keeper in it, as the server listed it:
 *  `DEFERRED · fusion_running`, `WAITING · hitl_pending +2`. The sources are
 *  the server's `state_sources`; nothing here picks them out of the rows. */
export function waitingStateWithSources(
  state: string | null | undefined,
  stateSources: readonly string[],
): string {
  const label = waitingStateLabel(state)
  const [first, ...rest] = stateSources
  if (first === undefined) return label
  return rest.length === 0 ? `${label} · ${first}` : `${label} · ${first} +${rest.length}`
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
    case 'observation_unavailable':
    case 'runtime_quota_spent':
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

function KeeperRow({ keeper, dev }: { keeper: DashboardKeeperWaitingKeeper; dev: boolean }) {
  const rows = keeper.waiting_on ?? []
  const waitingCount = keeper.waiting_count ?? 0
  return html`
    <div class="border-t border-[var(--color-border-subtle)] py-3 first:border-t-0" data-keeper-lane=${keeper.keeper_name}>
      <div class="mb-2 flex min-w-0 flex-wrap items-center justify-between gap-2">
        <div class="flex min-w-0 items-center gap-2">
          <span class="min-w-0 truncate font-mono text-sm text-[var(--color-fg-primary)]">${keeper.keeper_name}</span>
          <${StatusChip} tone=${stateTone(keeper.state)} uppercase=${false}>${waitingStateWithSources(keeper.state, keeper.state_sources)}<//>
        </div>
        <span class="text-2xs text-[var(--color-fg-muted)]">${waitingCount} rows</span>
      </div>
      <${SourceCounts} counts=${keeper.sources} />
      <div class="mt-2">
        <${LaneWaitingRows} rows=${rows} dev=${dev} actions=${null} />
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
              <${LaneWaitingRows} rows=${globalRows} dev=${dev} actions=${null} />
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
    `state ${waitingStateWithSources(keeper.state, keeper.state_sources)}`,
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
            <${StatusChip} tone=${stateTone(keeper.state)} uppercase=${false}>${waitingStateWithSources(keeper.state, keeper.state_sources)}<//>
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
          ? html`<${LaneWaitingRows} rows=${rows} dev=${dev} actions=${null} />`
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
              <${LaneWaitingRows} rows=${globalRows} dev=${dev} actions=${null} />
            </div>
          `
        : null}
    </div>
  `
}

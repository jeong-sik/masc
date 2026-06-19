import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { Activity, AlertTriangle, Bell, Radio, Users, X } from 'lucide-preact'
import type { JournalEntry, Keeper, Task } from '../types'
import { isKeeperCrashed } from '../lib/keeper-predicates'
import { dashboardWsOnlyEnabled } from '../dashboard-ws-cutover'
import {
  dashboardWsConnected,
  dashboardWsEventCount60s,
  dashboardWsLastError,
  dashboardWsLastEventAt,
  dashboardWsLastPongAt,
  dashboardWsLastPongLatencyMs,
  dashboardWsReady,
  dashboardWsSseFallbackActive,
  dashboardWsSseFallbackReason,
} from '../dashboard-ws-state'
import { route } from '../router'
import {
  keepers,
  staleKeepers,
  tasks,
} from '../store'
import {
  connected,
  journal,
  lastDisconnectedAt,
  reconnectCount,
} from '../sse'
import {
  DASHBOARD_WS_HEARTBEAT_INTERVAL_MS,
  DASHBOARD_WS_RPC_TIMEOUT_MS,
} from '../config/constants'
import { journalSeverity } from '../journal-entry'
import { TimeAgo } from './common/time-ago'
import { RouteLink } from './common/route-link'
import { ringFocusClasses } from './common/ring'
import { unacknowledgedCount } from './common/error-notification-state'

export const STATUS_TRAY_SILENT_MS = 30_000
export const STATUS_TRAY_HEARTBEAT_FRESH_MS =
  DASHBOARD_WS_HEARTBEAT_INTERVAL_MS + DASHBOARD_WS_RPC_TIMEOUT_MS + 1_000

export type StatusTrayKey = 'transport' | 'fleet' | 'activity' | 'attention'
export type StatusTrayTone = 'ok' | 'warn' | 'err' | 'muted'

export interface StatusTrayItem {
  key: StatusTrayKey
  tone: StatusTrayTone
  label: string
  value: string
  detail: string
}

export interface StatusTraySummary {
  items: Record<StatusTrayKey, StatusTrayItem>
  latestJournalEntries: JournalEntry[]
  counts: {
    totalKeepers: number
    freshKeepers: number
    staleKeepers: number
    keeperAttention: number
    pendingVerificationTasks: number
    unacknowledgedErrors: number
    reconnectCount: number
    wsEventCount60s: number
  }
}

export interface StatusTrayInput {
  wsOnly: boolean
  sseConnected: boolean
  wsConnected: boolean
  wsReady: boolean
  wsLastEventAt: number
  wsEventCount60s: number
  wsLastPongAt: number
  wsLastPongLatencyMs: number | null
  wsSseFallbackActive?: boolean
  wsSseFallbackReason?: string | null
  wsLastError: string | null
  reconnectCount: number
  lastDisconnectedAt: number
  keepers: readonly Keeper[]
  staleKeeperNames: ReadonlySet<string>
  tasks: readonly Task[]
  journalEntries: readonly JournalEntry[]
  unacknowledgedErrors: number
  now: number
}

interface DashboardStatusTrayProps {
  sideRailCollapsed?: boolean
}

const ITEM_META = {
  transport: { icon: Radio, title: 'Transport' },
  fleet: { icon: Users, title: 'Fleet' },
  activity: { icon: Activity, title: 'Activity' },
  attention: { icon: Bell, title: 'Attention' },
} as const

function clip(value: string | undefined, max = 90): string {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return 'No detail'
  return text.length > max ? `${text.slice(0, max - 3)}...` : text
}

function formatDisconnectedDetail(input: Pick<StatusTrayInput, 'lastDisconnectedAt' | 'reconnectCount' | 'now'>): string {
  const parts: string[] = []
  if (input.lastDisconnectedAt > 0) {
    const seconds = Math.max(0, Math.floor((input.now - input.lastDisconnectedAt) / 1000))
    parts.push(`offline ${seconds}s`)
  }
  if (input.reconnectCount > 0) {
    parts.push(`${input.reconnectCount} reconnects`)
  }
  return parts.length > 0 ? parts.join(' - ') : 'waiting for first connection'
}

function countPendingVerification(tasksInput: readonly Task[]): number {
  return tasksInput.filter(task => task.status === 'awaiting_verification').length
}

function hasExecutionAttentionEvidence(keeper: Keeper): boolean {
  const trust = keeper.trust
  if (trust?.needs_attention === true) return true
  const terminalSeverity = trust?.latest_terminal_reason?.severity?.trim().toLowerCase()
  if (terminalSeverity === 'bad' || terminalSeverity === 'warn') return true
  return false
}

function countKeeperAttention(keeperInput: readonly Keeper[]): number {
  return keeperInput.filter(keeper => {
    if (keeper.needs_attention) return true
    if (hasExecutionAttentionEvidence(keeper)) return true
    return isKeeperCrashed(keeper)
  }).length
}

function latestEntries(entries: readonly JournalEntry[]): JournalEntry[] {
  return entries.slice(0, 5)
}

type TransportInput = Pick<StatusTrayInput,
  | 'wsOnly' | 'sseConnected' | 'wsConnected' | 'wsReady'
  | 'wsLastEventAt' | 'wsEventCount60s' | 'wsLastPongAt' | 'wsLastPongLatencyMs'
  | 'wsSseFallbackActive' | 'wsSseFallbackReason' | 'wsLastError'
  | 'reconnectCount' | 'lastDisconnectedAt' | 'now'>

type FleetInput = Pick<StatusTrayInput,
  'keepers' | 'staleKeeperNames' | 'tasks' | 'journalEntries' | 'unacknowledgedErrors'>

interface FleetSummary {
  items: { fleet: StatusTrayItem; activity: StatusTrayItem; attention: StatusTrayItem }
  counts: {
    totalKeepers: number
    freshKeepers: number
    staleKeepers: number
    keeperAttention: number
    pendingVerificationTasks: number
    unacknowledgedErrors: number
  }
  latestJournalEntries: JournalEntry[]
}

// Transport item depends only on ws signals + `now` (Date.now()). Separated from
// the fleet/activity/attention cone so the latter can be memoized and skipped on
// ws deltas — dashboardWsLastEventAt updates on every WS event (very frequent),
// but transport is the only item that reads it.
function computeTransportItem(input: TransportInput): StatusTrayItem {
  if (input.wsOnly) {
    if (!input.wsConnected || !input.wsReady) {
      if (input.wsSseFallbackActive && input.sseConnected) {
        return {
          key: 'transport',
          tone: 'warn',
          label: 'Client',
          value: 'SSE fallback',
          detail: input.wsSseFallbackReason
            ? `client WS degraded; ${clip(input.wsSseFallbackReason)}`
            : 'client WS degraded; SSE fallback is live',
        }
      }
      return {
        key: 'transport',
        tone: 'err',
        label: 'Client',
        value: 'closed',
        detail: input.wsLastError
          ? clip(input.wsLastError)
          : 'client WS channel is not ready; server transport truth is in Diagnostics > Transport',
      }
    }
    const silentMs = input.wsLastEventAt === 0
      ? Number.POSITIVE_INFINITY
      : input.now - input.wsLastEventAt
    const silent = input.wsLastEventAt === 0 || silentMs > STATUS_TRAY_SILENT_MS
    const pongAgeMs = input.wsLastPongAt === 0
      ? Number.POSITIVE_INFINITY
      : input.now - input.wsLastPongAt
    const heartbeatFresh = pongAgeMs <= STATUS_TRAY_HEARTBEAT_FRESH_MS
    const pongLatency = input.wsLastPongLatencyMs == null
      ? 'pong'
      : `${input.wsLastPongLatencyMs}ms`
    return {
      key: 'transport',
      tone: silent && !heartbeatFresh ? 'warn' : 'ok',
      label: 'Client',
      value: silent
        ? heartbeatFresh ? pongLatency : 'silent'
        : `${input.wsEventCount60s} deltas/min`,
      detail: silent
        ? heartbeatFresh
          ? `client WS channel is idle; heartbeat pong ${Math.floor(pongAgeMs / 1000)}s ago`
          : 'client WS channel is open but no recent event or heartbeat pong has arrived'
        : `last applied route delta ${Math.floor(silentMs / 1000)}s ago`,
    }
  }
  return {
    key: 'transport',
    tone: input.sseConnected ? 'ok' : 'err',
    label: 'Client',
    value: input.sseConnected ? 'live' : 'offline',
    detail: input.sseConnected
      ? input.wsConnected
        ? 'client SSE is live with WS mirror connected'
        : 'client SSE is live'
      : formatDisconnectedDetail(input),
  }
}

// Fleet/activity/attention items + their counts. `now`-independent and ws-independent —
// memoizable on [keepers, staleKeeperNames, tasks, journalEntries, unacknowledgedErrors].
function computeFleetAttention(input: FleetInput): FleetSummary {
  const latest = latestEntries(input.journalEntries)
  const latestEntry = latest[0]
  const totalKeepers = input.keepers.length
  const staleCount = input.keepers.filter(keeper => input.staleKeeperNames.has(keeper.name)).length
  const keeperAttention = countKeeperAttention(input.keepers)
  const freshKeepers = Math.max(0, totalKeepers - staleCount)
  const pendingVerificationTasks = countPendingVerification(input.tasks)

  const fleetTone: StatusTrayTone = totalKeepers === 0
    ? 'muted'
    : staleCount === totalKeepers
      ? 'err'
      : staleCount > 0 || keeperAttention > 0
        ? 'warn'
        : 'ok'

  const activityTone: StatusTrayTone = !latestEntry
    ? 'muted'
    : journalSeverity(latestEntry) === 'error'
      ? 'err'
      : journalSeverity(latestEntry) === 'warn'
        ? 'warn'
        : 'ok'

  const attentionTotal = input.unacknowledgedErrors + keeperAttention + pendingVerificationTasks
  const attentionTone: StatusTrayTone = input.unacknowledgedErrors > 0
    ? 'err'
    : attentionTotal > 0
      ? 'warn'
      : 'ok'

  return {
    latestJournalEntries: latest,
    counts: {
      totalKeepers,
      freshKeepers,
      staleKeepers: staleCount,
      keeperAttention,
      pendingVerificationTasks,
      unacknowledgedErrors: input.unacknowledgedErrors,
    },
    items: {
      fleet: {
        key: 'fleet',
        tone: fleetTone,
        label: 'Keepers',
        value: totalKeepers === 0 ? 'none' : `fresh ${freshKeepers}/${totalKeepers}`,
        detail: staleCount > 0
          ? `${staleCount} stale heartbeat${staleCount === 1 ? '' : 's'}; freshness is separate from running fibers`
          : keeperAttention > 0
            ? `${keeperAttention} keeper${keeperAttention === 1 ? '' : 's'} need attention; heartbeat freshness is current`
            : 'keeper heartbeats are current',
      },
      activity: {
        key: 'activity',
        tone: activityTone,
        label: 'Pulse',
        value: latestEntry?.kind ?? 'idle',
        detail: latestEntry ? clip(latestEntry.preview ?? latestEntry.narrativeText ?? latestEntry.text) : 'no journal events loaded',
      },
      attention: {
        key: 'attention',
        tone: attentionTone,
        label: 'Attention',
        value: String(attentionTotal),
        detail: attentionTotal === 0
          ? 'no operator attention queued'
          : `${input.unacknowledgedErrors} errors - ${keeperAttention} keepers - ${pendingVerificationTasks} verify`,
      },
    },
  }
}

// Thin combiner preserving the original StatusTraySummary shape — tests call this
// directly and assert on items.* / counts.*, so the output must be byte-identical
// to the pre-split implementation.
export function summarizeStatusTray(input: StatusTrayInput): StatusTraySummary {
  const transport = computeTransportItem(input)
  const fleet = computeFleetAttention(input)
  return {
    latestJournalEntries: fleet.latestJournalEntries,
    counts: {
      ...fleet.counts,
      reconnectCount: input.reconnectCount,
      wsEventCount60s: input.wsEventCount60s,
    },
    items: {
      transport,
      ...fleet.items,
    },
  }
}

function TrayButton({
  item,
  active,
  onClick,
}: {
  item: StatusTrayItem
  active: boolean
  onClick: () => void
}) {
  const meta = ITEM_META[item.key]
  const Icon = meta.icon
  return html`
    <button
      type="button"
      class=${`v2-shell-action tray-button tone-${item.tone} ${active ? 'active' : ''} inline-flex h-9 shrink-0 items-center gap-2 rounded-[var(--r-1)] border border-solid px-2.5 text-left shadow-[var(--shadow-1)] transition-colors hover:bg-[var(--color-bg-hover)] max-[520px]:gap-1.5 max-[520px]:px-2 ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 1, offsetSurface: 'surface' })}`}
      title=${`${meta.title}: ${item.detail}`}
      aria-label=${`${meta.title}: ${item.value}. ${item.detail}`}
      aria-haspopup="dialog"
      aria-expanded=${active}
      aria-controls=${active ? 'dashboard-status-tray-popover' : undefined}
      data-testid=${`dashboard-status-tray-${item.key}`}
      onClick=${onClick}
    >
      <span class="tray-button-icon inline-flex size-4 shrink-0 items-center justify-center" aria-hidden="true">
        <${Icon} size=${14} strokeWidth=${2} />
      </span>
      <span class="grid min-w-0 grid-cols-1">
        <span class="tray-button-label font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)] opacity-75 max-[520px]:sr-only">${item.label}</span>
        <span class="tray-button-value max-w-24 truncate text-xs font-semibold leading-tight tracking-normal">${item.value}</span>
      </span>
    </button>
  `
}

function JournalPreviewList({ entries }: { entries: readonly JournalEntry[] }) {
  if (entries.length === 0) {
    return html`<p class="m-0 text-xs text-[var(--color-fg-muted)]">No recent journal entries.</p>`
  }
  return html`
    <ul class="m-0 grid list-none gap-1 p-0">
      ${entries.map(entry => html`
        <li class="v2-shell-row tray-journal-item min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="tray-journal-meta flex min-w-0 items-center gap-2">
            <span class="tray-journal-agent min-w-0 truncate text-xs font-medium text-[var(--color-fg-secondary)]">${entry.agent || entry.author || 'system'}</span>
            <span class="shrink-0 font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${entry.kind ?? 'system'}</span>
            <span class="ml-auto shrink-0 text-3xs text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${entry.timestamp} /></span>
          </div>
          <div class="tray-journal-preview mt-1 truncate text-xs text-[var(--color-fg-muted)]">${clip(entry.preview ?? entry.narrativeText ?? entry.text, 120)}</div>
        </li>
      `)}
    </ul>
  `
}

function PopoverContent({
  activeKey,
  summary,
}: {
  activeKey: StatusTrayKey
  summary: StatusTraySummary
}) {
  const item = summary.items[activeKey]
  if (activeKey === 'transport') {
    return html`
      <div class="grid gap-3">
        <div>
          <div class="tray-popover-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${item.label}</div>
          <div class="tray-popover-detail mt-0.5 text-sm font-semibold text-[var(--color-fg-secondary)]">${item.detail}</div>
        </div>
        <div class="grid grid-cols-2 gap-2">
          <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Reconnects</div>
            <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.reconnectCount}</div>
          </div>
          <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">WS deltas</div>
            <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.wsEventCount60s}/60s</div>
          </div>
        </div>
      </div>
    `
  }
  if (activeKey === 'fleet') {
    return html`
      <div class="grid gap-3">
        <div class="grid grid-cols-3 gap-2">
          <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Fresh</div>
            <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.freshKeepers}/${summary.counts.totalKeepers}</div>
          </div>
          <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Stale</div>
            <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.staleKeepers}</div>
          </div>
          <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Attention</div>
            <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.keeperAttention}</div>
          </div>
        </div>
        <${RouteLink} tab="monitoring" class="v2-shell-action tray-action-link inline-flex w-fit items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]">
          Open monitoring
        <//>
      </div>
    `
  }
  if (activeKey === 'activity') {
    return html`
      <div class="grid gap-3">
        <${JournalPreviewList} entries=${summary.latestJournalEntries} />
        <${RouteLink} tab="logs" class="v2-shell-action tray-action-link inline-flex w-fit items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]">
          Open logs
        <//>
      </div>
    `
  }
  return html`
    <div class="grid gap-3">
      <div class="grid grid-cols-3 gap-2">
        <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Errors</div>
          <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.unacknowledgedErrors}</div>
        </div>
        <div class="v2-shell-card tray-stat rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Keepers</div>
          <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.keeperAttention}</div>
        </div>
        <div class="v2-shell-card tray-stat ${summary.counts.pendingVerificationTasks >= 3 ? 'tone-warn' : ''} rounded-[var(--r-1)] border ${summary.counts.pendingVerificationTasks >= 3 ? 'border-[var(--warn-20)] bg-[var(--warn-10)]' : 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'} px-2 py-1.5">
          <div class="tray-stat-label font-mono text-3xs uppercase tracking-[var(--track-caps)] ${summary.counts.pendingVerificationTasks >= 3 ? 'text-[var(--warn-bright)]' : 'text-[var(--color-fg-muted)]'}">Verify</div>
          <div class="tray-stat-value mt-0.5 text-sm font-semibold tabular-nums ${summary.counts.pendingVerificationTasks >= 3 ? 'text-[var(--warn-bright)]' : ''}">${summary.counts.pendingVerificationTasks}</div>
        </div>
      </div>
      ${summary.counts.unacknowledgedErrors > 0 ? html`
        <div class="flex items-start gap-2 rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-soft)] px-2 py-1.5 text-xs text-[var(--color-status-err)]">
          <${AlertTriangle} size=${14} class="mt-0.5 shrink-0" aria-hidden="true" />
          <span>${summary.counts.unacknowledgedErrors} dashboard error${summary.counts.unacknowledgedErrors === 1 ? '' : 's'} need acknowledgement.</span>
        </div>
      ` : null}
    </div>
  `
}

const FLEET_TRAY_KEYS = ['fleet', 'activity', 'attention'] as const

const EMPTY_ITEM: StatusTrayItem = {
  key: 'transport',
  tone: 'muted',
  label: '',
  value: '',
  detail: '',
}

// Phase 2: signal subscriptions are isolated per chip so a ws delta
// (dashboardWsLastEventAt updates per WS event) re-renders only the transport
// chip — not the parent, the bar, or the fleet/activity/attention buttons.

// Reads only ws signals + now. ws deltas re-render this chip alone.
function TransportChip({ active, onActivate }: { active: boolean; onActivate: () => void }) {
  const transport = computeTransportItem({
    wsOnly: dashboardWsOnlyEnabled(),
    sseConnected: connected.value,
    wsConnected: dashboardWsConnected.value,
    wsReady: dashboardWsReady.value,
    wsLastEventAt: dashboardWsLastEventAt.value,
    wsEventCount60s: dashboardWsEventCount60s.value,
    wsLastPongAt: dashboardWsLastPongAt.value,
    wsLastPongLatencyMs: dashboardWsLastPongLatencyMs.value,
    wsSseFallbackActive: dashboardWsSseFallbackActive.value,
    wsSseFallbackReason: dashboardWsSseFallbackReason.value,
    wsLastError: dashboardWsLastError.value,
    reconnectCount: reconnectCount.value,
    lastDisconnectedAt: lastDisconnectedAt.value,
    now: Date.now(),
  })
  return html`<${TrayButton} item=${transport} active=${active} onClick=${onActivate} />`
}

// Reads only keepers/tasks/journal signals, memoized. ws deltas never reach it.
function FleetChips({
  activeKey,
  onActivate,
}: {
  activeKey: StatusTrayKey | null
  onActivate: (key: StatusTrayKey) => void
}) {
  const fleet = useMemo(
    () =>
      computeFleetAttention({
        keepers: keepers.value,
        staleKeeperNames: staleKeepers.value,
        tasks: tasks.value,
        journalEntries: journal.value,
        unacknowledgedErrors: unacknowledgedCount.value,
      }),
    [keepers.value, staleKeepers.value, tasks.value, journal.value, unacknowledgedCount.value],
  )
  return html`
    ${FLEET_TRAY_KEYS.map(key => html`
      <${TrayButton}
        item=${fleet.items[key]}
        active=${activeKey === key}
        onClick=${() => onActivate(key)}
      />
    `)}
  `
}

// Active-key popover. Reads only the signals the active key needs: ws signals
// for transport, keepers/tasks/journal for fleet/activity/attention. Reuses
// PopoverContent with a summary assembled for the active key (unused fields
// are zeroed — PopoverContent's active branch only reads its own fields).
function StatusTrayPopover({
  activeKey,
  onClose,
}: {
  activeKey: StatusTrayKey
  onClose: () => void
}) {
  let summary: StatusTraySummary
  if (activeKey === 'transport') {
    summary = {
      latestJournalEntries: [],
      counts: {
        totalKeepers: 0,
        freshKeepers: 0,
        staleKeepers: 0,
        keeperAttention: 0,
        pendingVerificationTasks: 0,
        unacknowledgedErrors: 0,
        reconnectCount: reconnectCount.value,
        wsEventCount60s: dashboardWsEventCount60s.value,
      },
      items: {
        transport: computeTransportItem({
          wsOnly: dashboardWsOnlyEnabled(),
          sseConnected: connected.value,
          wsConnected: dashboardWsConnected.value,
          wsReady: dashboardWsReady.value,
          wsLastEventAt: dashboardWsLastEventAt.value,
          wsEventCount60s: dashboardWsEventCount60s.value,
          wsLastPongAt: dashboardWsLastPongAt.value,
          wsLastPongLatencyMs: dashboardWsLastPongLatencyMs.value,
          wsSseFallbackActive: dashboardWsSseFallbackActive.value,
          wsSseFallbackReason: dashboardWsSseFallbackReason.value,
          wsLastError: dashboardWsLastError.value,
          reconnectCount: reconnectCount.value,
          lastDisconnectedAt: lastDisconnectedAt.value,
          now: Date.now(),
        }),
        fleet: EMPTY_ITEM,
        activity: EMPTY_ITEM,
        attention: EMPTY_ITEM,
      },
    }
  } else {
    const fleet = computeFleetAttention({
      keepers: keepers.value,
      staleKeeperNames: staleKeepers.value,
      tasks: tasks.value,
      journalEntries: journal.value,
      unacknowledgedErrors: unacknowledgedCount.value,
    })
    summary = {
      latestJournalEntries: fleet.latestJournalEntries,
      counts: { ...fleet.counts, reconnectCount: 0, wsEventCount60s: 0 },
      items: { transport: EMPTY_ITEM, ...fleet.items },
    }
  }
  const item = summary.items[activeKey]
  return html`
    <div
      id="dashboard-status-tray-popover"
      data-testid="dashboard-status-tray-popover"
      role="dialog"
      aria-label=${`${item.label} details`}
      class=${`v2-shell-panel tray-popover tone-${item.tone} absolute bottom-full left-0 mb-2 w-[22rem] max-w-[calc(100vw-1rem)] rounded-[var(--r-2)] border border-solid bg-[var(--color-bg-panel)] p-3 text-[var(--color-fg-primary)] shadow-[var(--shadow-panel)] max-[520px]:w-full`}
    >
      <div class="v2-shell-toolbar tray-popover-head mb-3 flex min-w-0 items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="tray-popover-label font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${item.label}</div>
          <div class="tray-popover-detail mt-0.5 truncate text-sm font-semibold text-[var(--color-fg-secondary)]">${item.detail}</div>
        </div>
        <button
          type="button"
          class=${`v2-shell-action tray-popover-close inline-flex size-7 shrink-0 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-xs text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 1, offsetSurface: 'surface' })}`}
          aria-label="Close status tray details"
          onClick=${onClose}
        >
          <${X} size=${14} aria-hidden="true" />
        </button>
      </div>
      <${PopoverContent} activeKey=${activeKey} summary=${summary} />
    </div>
  `
}

// Slim parent: owns activeKey + layout + outside-click only. Reads no ws/keepers
// signals (only route.value.tab for the code offset), so ws deltas cannot reach it.
export function DashboardStatusTray({ sideRailCollapsed = false }: DashboardStatusTrayProps) {
  const [activeKey, setActiveKey] = useState<StatusTrayKey | null>(null)
  const trayRef = useRef<HTMLElement>(null)

  useEffect(() => {
    if (!activeKey) return undefined
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setActiveKey(null)
      }
    }
    const onPointerDown = (event: MouseEvent | TouchEvent) => {
      const target = event.target as Node | null
      if (!target || trayRef.current?.contains(target)) return
      setActiveKey(null)
    }
    document.addEventListener('keydown', onKeyDown)
    document.addEventListener('mousedown', onPointerDown, true)
    document.addEventListener('touchstart', onPointerDown, true)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.removeEventListener('mousedown', onPointerDown, true)
      document.removeEventListener('touchstart', onPointerDown, true)
    }
  }, [activeKey])

  const codeOffset = route.value.tab === 'code' ? 'bottom-16' : 'bottom-3 max-[520px]:bottom-2'
  const sideRailOffset = sideRailCollapsed ? 'left-[4.75rem]' : 'left-[14.75rem]'

  const activate = (key: StatusTrayKey) => setActiveKey(activeKey === key ? null : key)

  return html`
    <aside
      ref=${trayRef}
      class=${`v2-status-tray dashboard-status-tray fixed z-40 max-w-[calc(100vw-1.5rem)] ${sideRailOffset} max-[1100px]:left-2 max-[1100px]:right-2 max-[1100px]:max-w-none ${codeOffset}`}
      aria-label="Dashboard status tray"
      data-testid="dashboard-status-tray"
    >
      ${activeKey ? html`<${StatusTrayPopover} activeKey=${activeKey} onClose=${() => setActiveKey(null)} />` : null}

      <div class="v2-tray-bar inline-flex max-w-full items-center gap-1 overflow-x-auto rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--shell-header-bg)] p-1 shadow-[var(--shadow-panel)] [scrollbar-width:none]">
        <${TransportChip} active=${activeKey === 'transport'} onActivate=${() => activate('transport')} />
        <${FleetChips} activeKey=${activeKey} onActivate=${activate} />
      </div>
    </aside>
  `
}

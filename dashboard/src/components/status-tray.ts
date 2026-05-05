import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { Activity, AlertTriangle, Bell, Radio, Users, X } from 'lucide-preact'
import type { JournalEntry, Keeper, Task } from '../types'
import { dashboardWsOnlyEnabled } from '../dashboard-ws-cutover'
import {
  dashboardWsConnected,
  dashboardWsEventCount60s,
  dashboardWsLastError,
  dashboardWsLastEventAt,
  dashboardWsReady,
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
import { journalSeverity } from '../journal-entry'
import { TimeAgo } from './common/time-ago'
import { RouteLink } from './common/route-link'
import { ringFocusClasses } from './common/ring'
import { unacknowledgedCount } from './common/error-notification-state'

export const STATUS_TRAY_SILENT_MS = 30_000

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
    staleKeepers: number
    keeperAttention: number
    pendingVerificationTasks: number
    unacknowledgedErrors: number
  }
}

export interface StatusTrayInput {
  wsOnly: boolean
  sseConnected: boolean
  wsConnected: boolean
  wsReady: boolean
  wsLastEventAt: number
  wsEventCount60s: number
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

const TRAY_ORDER: StatusTrayKey[] = ['transport', 'fleet', 'activity', 'attention']

const TONE_CLASS: Record<StatusTrayTone, string> = {
  ok: 'border-[var(--color-status-ok)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]',
  warn: 'border-[var(--color-status-warn)] bg-[var(--warn-soft)] text-[var(--color-status-warn)]',
  err: 'border-[var(--color-status-err)] bg-[var(--bad-soft)] text-[var(--color-status-err)]',
  muted: 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]',
}

const PANEL_TONE_CLASS: Record<StatusTrayTone, string> = {
  ok: 'border-[var(--ok-30)]',
  warn: 'border-[var(--warn-30)]',
  err: 'border-[var(--bad-30)]',
  muted: 'border-[var(--color-border-default)]',
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

function countKeeperAttention(keeperInput: readonly Keeper[]): number {
  return keeperInput.filter(keeper => {
    if (keeper.needs_attention) return true
    const status = (keeper.status ?? '').toLowerCase()
    return status.includes('crash') || status === 'dead' || status === 'zombie'
  }).length
}

function latestEntries(entries: readonly JournalEntry[]): JournalEntry[] {
  return [...entries]
    .sort((left, right) => right.timestamp - left.timestamp)
    .slice(0, 5)
}

export function summarizeStatusTray(input: StatusTrayInput): StatusTraySummary {
  const latest = latestEntries(input.journalEntries)
  const latestEntry = latest[0]
  const totalKeepers = input.keepers.length
  const staleCount = input.keepers.filter(keeper => input.staleKeeperNames.has(keeper.name)).length
  const keeperAttention = countKeeperAttention(input.keepers)
  const activeKeepers = Math.max(0, totalKeepers - staleCount)
  const pendingVerificationTasks = countPendingVerification(input.tasks)

  let transport: StatusTrayItem
  if (input.wsOnly) {
    if (!input.wsConnected || !input.wsReady) {
      transport = {
        key: 'transport',
        tone: 'err',
        label: 'WS',
        value: 'closed',
        detail: input.wsLastError ? clip(input.wsLastError) : 'WS-only channel is not ready',
      }
    } else {
      const silentMs = input.wsLastEventAt === 0
        ? Number.POSITIVE_INFINITY
        : input.now - input.wsLastEventAt
      const silent = input.wsLastEventAt === 0 || silentMs > STATUS_TRAY_SILENT_MS
      transport = {
        key: 'transport',
        tone: silent ? 'warn' : 'ok',
        label: 'WS',
        value: silent ? 'silent' : `${input.wsEventCount60s}/60s`,
        detail: silent
          ? 'WS-only channel is open but no recent event has arrived'
          : `last event ${Math.floor(silentMs / 1000)}s ago`,
      }
    }
  } else {
    transport = {
      key: 'transport',
      tone: input.sseConnected ? 'ok' : 'err',
      label: 'SSE',
      value: input.sseConnected ? 'live' : 'offline',
      detail: input.sseConnected
        ? input.wsConnected ? 'SSE is live with WS shadow channel connected' : 'SSE is live'
        : formatDisconnectedDetail(input),
    }
  }

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
      staleKeepers: staleCount,
      keeperAttention,
      pendingVerificationTasks,
      unacknowledgedErrors: input.unacknowledgedErrors,
    },
    items: {
      transport,
      fleet: {
        key: 'fleet',
        tone: fleetTone,
        label: 'Keepers',
        value: totalKeepers === 0 ? 'none' : `${activeKeepers}/${totalKeepers}`,
        detail: staleCount > 0
          ? `${staleCount} stale heartbeat${staleCount === 1 ? '' : 's'}`
          : keeperAttention > 0
            ? `${keeperAttention} keeper${keeperAttention === 1 ? '' : 's'} need attention`
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
      class=${`inline-flex h-9 shrink-0 items-center gap-2 rounded-[var(--r-1)] border border-solid px-2.5 text-left shadow-[var(--shadow-1)] transition-colors hover:bg-[var(--color-bg-hover)] max-[520px]:gap-1.5 max-[520px]:px-2 ${TONE_CLASS[item.tone]} ${active ? 'ring-2 ring-[var(--select-20)]' : ''} ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 1, offsetSurface: 'surface' })}`}
      title=${`${meta.title}: ${item.detail}`}
      aria-label=${`${meta.title}: ${item.value}. ${item.detail}`}
      aria-expanded=${active}
      aria-controls=${active ? 'dashboard-status-tray-popover' : undefined}
      data-testid=${`dashboard-status-tray-${item.key}`}
      onClick=${onClick}
    >
      <span class="inline-flex size-4 shrink-0 items-center justify-center" aria-hidden="true">
        <${Icon} size=${14} strokeWidth=${2} />
      </span>
      <span class="grid min-w-0 grid-cols-1">
        <span class="font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)] opacity-75 max-[520px]:sr-only">${item.label}</span>
        <span class="max-w-24 truncate text-xs font-semibold leading-tight tracking-normal">${item.value}</span>
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
        <li class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="flex min-w-0 items-center gap-2">
            <span class="min-w-0 truncate text-xs font-medium text-[var(--color-fg-secondary)]">${entry.agent || entry.author || 'system'}</span>
            <span class="shrink-0 font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${entry.kind ?? 'system'}</span>
            <span class="ml-auto shrink-0 text-3xs text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${entry.timestamp} /></span>
          </div>
          <div class="mt-1 truncate text-xs text-[var(--color-fg-muted)]">${clip(entry.preview ?? entry.narrativeText ?? entry.text, 120)}</div>
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
          <div class="text-sm font-semibold text-[var(--color-fg-secondary)]">${item.value}</div>
          <div class="mt-1 text-xs text-[var(--color-fg-muted)]">${item.detail}</div>
        </div>
        <div class="grid grid-cols-2 gap-2">
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Reconnects</div>
            <div class="mt-0.5 text-sm font-semibold tabular-nums">${reconnectCount.value}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">WS events</div>
            <div class="mt-0.5 text-sm font-semibold tabular-nums">${dashboardWsEventCount60s.value}/60s</div>
          </div>
        </div>
      </div>
    `
  }
  if (activeKey === 'fleet') {
    return html`
      <div class="grid gap-3">
        <div class="grid grid-cols-3 gap-2">
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Total</div>
            <div class="mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.totalKeepers}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Stale</div>
            <div class="mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.staleKeepers}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
            <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Attention</div>
            <div class="mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.keeperAttention}</div>
          </div>
        </div>
        <${RouteLink} tab="monitoring" class="inline-flex w-fit items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]">
          Open monitoring
        <//>
      </div>
    `
  }
  if (activeKey === 'activity') {
    return html`
      <div class="grid gap-3">
        <${JournalPreviewList} entries=${summary.latestJournalEntries} />
        <${RouteLink} tab="logs" class="inline-flex w-fit items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]">
          Open logs
        <//>
      </div>
    `
  }
  return html`
    <div class="grid gap-3">
      <div class="grid grid-cols-3 gap-2">
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Errors</div>
          <div class="mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.unacknowledgedErrors}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Keepers</div>
          <div class="mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.keeperAttention}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
          <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Verify</div>
          <div class="mt-0.5 text-sm font-semibold tabular-nums">${summary.counts.pendingVerificationTasks}</div>
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

export function DashboardStatusTray({ sideRailCollapsed = false }: DashboardStatusTrayProps) {
  const [activeKey, setActiveKey] = useState<StatusTrayKey | null>(null)
  const wsOnly = dashboardWsOnlyEnabled()
  const summary = summarizeStatusTray({
    wsOnly,
    sseConnected: connected.value,
    wsConnected: dashboardWsConnected.value,
    wsReady: dashboardWsReady.value,
    wsLastEventAt: dashboardWsLastEventAt.value,
    wsEventCount60s: dashboardWsEventCount60s.value,
    wsLastError: dashboardWsLastError.value,
    reconnectCount: reconnectCount.value,
    lastDisconnectedAt: lastDisconnectedAt.value,
    keepers: keepers.value,
    staleKeeperNames: staleKeepers.value,
    tasks: tasks.value,
    journalEntries: journal.value,
    unacknowledgedErrors: unacknowledgedCount.value,
    now: Date.now(),
  })

  useEffect(() => {
    if (!activeKey) return undefined
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setActiveKey(null)
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [activeKey])

  const activeItem = activeKey ? summary.items[activeKey] : null
  const codeOffset = route.value.tab === 'code' ? 'bottom-16' : 'bottom-3 max-[520px]:bottom-2'
  const sideRailOffset = sideRailCollapsed ? 'left-[4.75rem]' : 'left-[14.75rem]'

  return html`
    <aside
      class=${`fixed z-40 max-w-[calc(100vw-1.5rem)] ${sideRailOffset} max-[1100px]:left-2 max-[1100px]:right-2 max-[1100px]:max-w-none ${codeOffset}`}
      aria-label="Dashboard status tray"
      data-testid="dashboard-status-tray"
    >
      ${activeItem ? html`
        <div
          id="dashboard-status-tray-popover"
          data-testid="dashboard-status-tray-popover"
          role="dialog"
          aria-label=${`${activeItem.label} details`}
          class=${`absolute bottom-full left-0 mb-2 w-[22rem] max-w-[calc(100vw-1rem)] rounded-[var(--r-2)] border border-solid bg-[var(--color-bg-panel)] p-3 text-[var(--color-fg-primary)] shadow-[var(--shadow-panel)] backdrop-blur-xl ${PANEL_TONE_CLASS[activeItem.tone]} max-[520px]:w-full`}
        >
          <div class="mb-3 flex min-w-0 items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${activeItem.label}</div>
              <div class="mt-0.5 truncate text-sm font-semibold text-[var(--color-fg-secondary)]">${activeItem.detail}</div>
            </div>
            <button
              type="button"
              class=${`inline-flex size-7 shrink-0 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-xs text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 1, offsetSurface: 'surface' })}`}
              aria-label="Close status tray details"
              onClick=${() => { setActiveKey(null) }}
            >
              <${X} size=${14} aria-hidden="true" />
            </button>
          </div>
          <${PopoverContent} activeKey=${activeKey} summary=${summary} />
        </div>
      ` : null}

      <div class="inline-flex max-w-full items-center gap-1 overflow-x-auto rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--shell-header-bg)] p-1 shadow-[var(--shadow-panel)] backdrop-blur-xl [scrollbar-width:none]">
        ${TRAY_ORDER.map(key => html`
          <${TrayButton}
            item=${summary.items[key]}
            active=${activeKey === key}
            onClick=${() => { setActiveKey(activeKey === key ? null : key) }}
          />
        `)}
      </div>
    </aside>
  `
}

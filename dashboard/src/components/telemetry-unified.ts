// Telemetry Unified — MASC runtime diagnosis view.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchDashboardShell,
  fetchDashboardTools,
  fetchDashboardNamespaceTruth,
  fetchTelemetry,
  type TelemetryEntry,
  type TelemetrySource,
  type TelemetrySourceSummary,
} from '../api/dashboard'
import {
  refreshSharedTelemetrySummary,
  sharedTelemetrySummary,
  sharedTelemetrySummaryError,
} from './fleet-data-core'
import { route } from '../router'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { TELEMETRY_SOURCE_META, telemetrySourceMeta } from '../config/telemetry-sources'
import { formatTimeAgo } from '../lib/format-time'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { isAbortError } from '../lib/async-state'
import { OasHealthChip } from './oas-health-chip'
import { CopyIdButton } from './common/copy-id-button'

interface StoreSnapshot {
  keepers: number
  agents: number
  tasks: number
  activeOperations: number
  blockedOperations: number
  continuityAlerts: number
  toolsRegistered: number
  toolsPublic: number
  toolsTotalCalls: number
  toolsNeverCalled: number
  version: string | null
  uptime: number | null
}

const EMPTY_STORE: StoreSnapshot = {
  keepers: 0, agents: 0, tasks: 0,
  activeOperations: 0, blockedOperations: 0, continuityAlerts: 0,
  toolsRegistered: 0, toolsPublic: 0, toolsTotalCalls: 0, toolsNeverCalled: 0,
  version: null, uptime: null,
}
interface TelemetryState {
  entries: TelemetryEntry[]
  summary: TelemetrySourceSummary[]
  totalEntries: number
  store: StoreSnapshot
  loading: boolean
  error: string | null
}

const sourceMeta = telemetrySourceMeta

type TelemetryCondensedCategory = 'heartbeat' | 'polling'

export type TelemetryDisplayItem =
  | {
      kind: 'entry'
      key: string
      entry: TelemetryEntry
    }
  | {
      kind: 'group'
      key: string
      category: TelemetryCondensedCategory
      label: string
      count: number
      latestTs: number
      oldestTs: number
      entries: TelemetryEntry[]
      sourceKeys: TelemetrySource[]
      scopeBadges: string[]
    }

const CONDENSED_CATEGORY_META: Record<TelemetryCondensedCategory, {
  label: string
  icon: string
  color: string
}> = {
  heartbeat: {
    label: 'Heartbeat',
    icon: 'H',
    color: 'text-[var(--accent)]',
  },
  polling: {
    label: 'Polling / no-op',
    icon: 'P',
    color: 'text-[var(--accent)]',
  },
}

const NOISY_TOOL_NAMES = new Set([
  'masc_status',
  'masc_tasks',
  'masc_messages',
  'masc_who',
  'keeper_tasks_list',
  'keeper_stay_silent',
  'extend_turns',
])

function entryTimestamp(e: TelemetryEntry): number {
  const numeric = (e.ts_unix as number) ?? (e.ts as number) ?? (e.timestamp as number) ?? 0
  if (numeric > 0) return numeric
  if (typeof e.ts_iso === 'string') {
    const parsed = Date.parse(e.ts_iso)
    if (!Number.isNaN(parsed)) return parsed / 1000
  }
  return 0
}

function formatTs(ts: number): string {
  if (ts === 0) return '-'
  const d = new Date(ts * 1000)
  return d.toLocaleString('ko-KR', {
    month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function timeAgoSafe(ts: number): string {
  return ts === 0 ? '' : formatTimeAgo(ts)
}

function normalizeText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function normalizeStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string' && item.trim() !== '') : []
}

function recordField(value: unknown, key: string): unknown {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  return (value as Record<string, unknown>)[key]
}

function uniqueStrings(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const normalized = normalizeText(value)
    if (!normalized || seen.has(normalized)) continue
    seen.add(normalized)
    result.push(normalized)
  }
  return result
}

function compactId(value: string | null | undefined, prefix: string): string | null {
  if (!value) return null
  return `${prefix} ${value}`
}

function telemetryScopeBadges(entry: TelemetryEntry): string[] {
  return [
    compactId(normalizeText(entry.session_id), 'S'),
    compactId(normalizeText(entry.operation_id), 'OP'),
    compactId(normalizeText(entry.worker_run_id), 'WR'),
  ].filter((value): value is string => Boolean(value))
}

function telemetryToolName(entry: TelemetryEntry): string | null {
  if (entry.source === 'tool_call_io') return normalizeText(entry.tool)
  if (entry.source === 'tool_usage' || entry.source === 'tool_metric' || entry.source === 'trajectory_tool_call') {
    return normalizeText(entry.tool_name)
      ?? normalizeText(recordField(entry.action_radius, 'tool_name'))
  }
  if (entry.source === 'execution_receipt') {
    return normalizeStringArray(entry.canonical_tools)[0]
      ?? normalizeText(recordField(entry.action_radius, 'tool_name'))
  }
  return null
}

function canonicalToolName(value: string | null): string | null {
  if (!value) return null
  // Split on double-underscore and take the last segment to handle
  // server names that contain underscores or dashes (e.g. mcp__my_server__toolName).
  if (value.startsWith('mcp__')) {
    const segments = value.split('__')
    // segments: ['mcp', '<server>', '<tool>'] — take the last non-empty segment
    const tool = segments.length >= 3 ? segments[segments.length - 1] : value
    return normalizeText(tool ?? value)
  }
  return normalizeText(value)
}

function entryGroupingDescriptor(entry: TelemetryEntry): {
  key: string
  category: TelemetryCondensedCategory
  label: string
} | null {
  if (entry.source === 'keeper_metric' && normalizeText(entry.channel) === 'heartbeat') {
    const keeper = normalizeText(entry.name) ?? 'unknown'
    const scope = normalizeText(entry.session_id) ?? normalizeText(entry.operation_id) ?? keeper
    return {
      key: `heartbeat:${scope}:${keeper}`,
      category: 'heartbeat',
      label: `${keeper} heartbeat`,
    }
  }

  const tool = canonicalToolName(telemetryToolName(entry))
  if (!tool || !NOISY_TOOL_NAMES.has(tool)) return null

  const scope =
    normalizeText(entry.session_id)
    ?? normalizeText(entry.operation_id)
    ?? normalizeText(entry.worker_run_id)
    ?? normalizeText(entry.keeper)
    ?? normalizeText(entry.keeper_name)
    ?? normalizeText(entry.name)
    ?? normalizeText(entry.caller)
    ?? normalizeText(entry.agent_name)
    ?? 'global'

  return {
    key: `polling:${scope}:${tool}`,
    category: 'polling',
    label: tool,
  }
}

function entryPreview(e: TelemetryEntry): string {
  switch (e.source) {
    case 'keeper_metric': {
      const name = normalizeText(e.name) ?? '-'
      const channel = normalizeText(e.channel) ?? '-'
      const rawModel = normalizeText(e.model_used)
      const isStatusTag = rawModel != null && /^(turn-exhausted|unknown|none|-)$/i.test(rawModel)
      const model = rawModel == null ? '-' : isStatusTag ? `(${rawModel})` : rawModel
      const tools = normalizeStringArray(e.tools_used)
      const toolCount = typeof e.tool_call_count === 'number' ? e.tool_call_count : tools.length
      return `${name} [${channel}] model=${model} tools=${toolCount}`
    }
    case 'agent_event': {
      const event = e.event
      if (Array.isArray(event)) {
        const tag = String(event[0] ?? 'unknown')
        const detail = event[1] as Record<string, unknown> | undefined
        if (detail) {
          const parts = [
            normalizeText(detail.agent_id as string),
            normalizeText(detail.tool_name as string),
          ].filter(Boolean)
          return parts.length > 0 ? `${tag}: ${parts.join(' -> ')}` : tag
        }
        return tag
      }
      return String(event ?? '')
    }
    case 'tool_call_io': {
      const tool = normalizeText(e.tool) ?? ''
      const keeper = normalizeText(e.keeper) ?? ''
      return `${keeper} -> ${tool}`
    }
    case 'trajectory_tool_call': {
      const tool = telemetryToolName(e) ?? 'tool'
      const keeper =
        normalizeText(e.keeper_name)
        ?? normalizeText(recordField(e.runtime_contract, 'keeper_name'))
        ?? normalizeText(e.keeper)
        ?? 'unknown'
      return `${keeper} -> ${tool}`
    }
    case 'tool_usage': {
      const tool = normalizeText(e.tool_name) ?? ''
      const caller = normalizeText(e.caller) ?? ''
      return `${caller || 'unknown'} -> ${tool}`
    }
    case 'oas_event': {
      const eventType = normalizeText(e.event_type) ?? normalizeText(e.type) ?? 'oas'
      const agentName = normalizeText(e.agent_name)
      const toolName = normalizeText(e.tool_name)
      const turn = typeof e.turn === 'number' ? e.turn : null
      const taskId = normalizeText(e.task_id)
      const parts = [
        agentName,
        toolName,
        turn != null ? `turn ${turn}` : null,
        taskId,
      ].filter(Boolean)
      return parts.length > 0 ? `${eventType}: ${parts.join(' · ')}` : eventType
    }
    case 'execution_receipt': {
      const keeper = normalizeText(e.keeper_name) ?? normalizeText(e.agent_name) ?? 'unknown'
      const outcome = normalizeText(e.outcome) ?? normalizeText(e.operator_disposition) ?? 'recorded'
      const reason = normalizeText(e.terminal_reason_code)
      return reason ? `${keeper} receipt ${outcome} (${reason})` : `${keeper} receipt ${outcome}`
    }
    case 'goal_event': {
      const goal = normalizeText(e.goal_id) ?? 'unknown-goal'
      const eventType = normalizeText(e.event_type) ?? 'goal_event'
      return `${goal} ${eventType}`
    }
    case 'tool_metric': {
      const tool = normalizeText(e.tool_name) ?? ''
      const dur = typeof e.duration_ms === 'number' ? e.duration_ms : null
      return `${tool} ${dur != null ? dur.toFixed(0) + 'ms' : ''}`
    }
    default:
      return JSON.stringify(e).slice(0, 80)
  }
}

/**
 * Case-insensitive substring search over the rendered telemetry display items.
 *
 * Matches against, in order (first match wins):
 * - `entry.source` (for entry rows) or concatenated source keys (for groups)
 * - `entryPreview(entry)` text (for entry rows) or `item.label` (for groups),
 *   which already captures keeper/tool/agent identifiers
 * - scope badges ("S ...", "OP ...", "WR ...") from session/operation/worker_run
 *
 * Empty or whitespace-only queries return the input reference unchanged so the
 * non-filter path keeps reference identity (useMemo/inline-path friendly).
 * Input is never mutated; items are treated as readonly.
 */
export function filterTelemetryDisplayItems(
  items: readonly TelemetryDisplayItem[],
  query: string,
): readonly TelemetryDisplayItem[] {
  const trimmed = query.trim()
  if (trimmed === '') return items
  const needle = trimmed.toLowerCase()

  const haystackForItem = (item: TelemetryDisplayItem): string => {
    if (item.kind === 'entry') {
      const source = typeof item.entry.source === 'string' ? item.entry.source : ''
      const preview = entryPreview(item.entry)
      const badges = telemetryScopeBadges(item.entry).join(' ')
      return `${source} ${preview} ${badges}`
    }
    const sources = item.sourceKeys.join(' ')
    const badges = item.scopeBadges.join(' ')
    return `${sources} ${item.label} ${badges}`
  }

  return items.filter(item => haystackForItem(item).toLowerCase().includes(needle))
}

export function buildTelemetryDisplayItems(entries: TelemetryEntry[]): TelemetryDisplayItem[] {
  const items: TelemetryDisplayItem[] = []
  let nextItemId = 0
  let activeGroup: {
    key: string
    category: TelemetryCondensedCategory
    label: string
    entries: TelemetryEntry[]
    latestTs: number
    oldestTs: number
    sourceKeys: Set<TelemetrySource>
    scopeBadges: string[]
  } | null = null

  const flushGroup = () => {
    if (!activeGroup) return
    if (activeGroup.entries.length === 1) {
      const entry = activeGroup.entries[0] as TelemetryEntry
      items.push({
        kind: 'entry',
        key: `${activeGroup.key}:${activeGroup.latestTs}:${nextItemId}`,
        entry,
      })
      nextItemId += 1
    } else {
      items.push({
        kind: 'group',
        key: `${activeGroup.key}:${activeGroup.latestTs}:${activeGroup.entries.length}:${nextItemId}`,
        category: activeGroup.category,
        label: activeGroup.label,
        count: activeGroup.entries.length,
        latestTs: activeGroup.latestTs,
        oldestTs: activeGroup.oldestTs,
        entries: activeGroup.entries,
        sourceKeys: Array.from(activeGroup.sourceKeys),
        scopeBadges: activeGroup.scopeBadges,
      })
      nextItemId += 1
    }
    activeGroup = null
  }

  for (const entry of entries) {
    const descriptor = entryGroupingDescriptor(entry)
    if (!descriptor) {
      flushGroup()
      items.push({
        kind: 'entry',
        key: `${entry.source}:${entryTimestamp(entry)}:${nextItemId}`,
        entry,
      })
      nextItemId += 1
      continue
    }

    const ts = entryTimestamp(entry)
    if (activeGroup && activeGroup.key === descriptor.key) {
      activeGroup.entries.push(entry)
      if (activeGroup.latestTs === 0 && ts !== 0) activeGroup.latestTs = ts
      if (activeGroup.oldestTs === 0) activeGroup.oldestTs = ts
      else if (ts !== 0) activeGroup.oldestTs = Math.min(activeGroup.oldestTs, ts)
      activeGroup.sourceKeys.add(entry.source)
      activeGroup.scopeBadges = uniqueStrings([
        ...activeGroup.scopeBadges,
        ...telemetryScopeBadges(entry),
      ])
      continue
    }

    flushGroup()
    activeGroup = {
      key: descriptor.key,
      category: descriptor.category,
      label: descriptor.label,
      entries: [entry],
      latestTs: ts,
      oldestTs: ts,
      sourceKeys: new Set([entry.source]),
      scopeBadges: telemetryScopeBadges(entry),
    }
  }

  flushGroup()
  return items
}

function condensedStats(items: readonly TelemetryDisplayItem[]) {
  let groups = 0
  let groupedEntries = 0
  let collapsedEntries = 0
  const byCategory = new Map<TelemetryCondensedCategory, number>()
  for (const item of items) {
    if (item.kind !== 'group') continue
    groups += 1
    groupedEntries += item.count
    collapsedEntries += Math.max(0, item.count - 1)
    byCategory.set(item.category, (byCategory.get(item.category) ?? 0) + item.count)
  }
  return { groups, groupedEntries, collapsedEntries, byCategory }
}

function SummaryCard({ src }: { src: TelemetrySourceSummary }) {
  const meta = sourceMeta(src.source)
  const hasData = src.entry_count > 0

  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3 min-w-35">
      <div class="flex items-center gap-2 mb-1">
        <span class="font-mono font-bold ${meta.color}">${meta.icon}</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${meta.label}</span>
      </div>
      ${meta.sublabel ? html`<div class="text-3xs text-[var(--text-dim)] mb-1">${meta.sublabel}</div>` : null}
      <div class="text-2xl font-bold ${hasData ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'}">
        ${src.entry_count.toLocaleString()}
      </div>
      ${src.keeper_count != null ? html`
        <div class="text-xs text-[var(--text-muted)]">${src.keeper_count} keepers</div>
      ` : null}
      ${src.exists === false ? html`
        <div class="text-xs text-[var(--text-muted)] italic">store not found</div>
      ` : null}
    </div>
  `
}

function DiagnosisCard({ title, value, detail, tone }: { title: string; value: string; detail: string; tone: 'ok' | 'warn' | 'neutral' }) {
  const toneColor = tone === 'ok' ? 'text-[var(--ok)]' : tone === 'warn' ? 'text-[var(--warn)]' : 'text-[var(--text-muted)]'
  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3 min-w-35">
      <div class="text-xs font-medium text-[var(--text-muted)] mb-1">${title}</div>
      <div class="text-2xl font-bold ${toneColor}">${value}</div>
      <div class="text-3xs text-[var(--text-dim)]">${detail}</div>
    </div>
  `
}

function EntryRow({ entry }: { entry: TelemetryEntry }) {
  const expanded = useSignal(false)
  const meta = sourceMeta(entry.source)
  const ts = entryTimestamp(entry)
  const success = entry.success as boolean | undefined
  const scopeBadges = telemetryScopeBadges(entry)
  const rawJson = JSON.stringify(entry, null, 2)

  return html`
    <div
      class="border-b border-[var(--card-border)] hover:bg-[var(--bg-panel-hover)] transition-colors"
      style="content-visibility:auto;contain-intrinsic-size:36px"
    >
      <div class="flex items-center gap-1">
        <button
          type="button"
          class="min-w-0 flex-1 flex items-center gap-2 px-3 py-1.5 text-xs cursor-pointer select-none text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent"
          onClick=${() => { expanded.value = !expanded.value }}
          aria-expanded=${expanded.value}
        >
          <span class="font-mono font-bold ${meta.color} w-4 text-center flex-shrink-0">${meta.icon}</span>
          <span class="font-mono text-[var(--text-muted)] w-28 flex-shrink-0" title=${formatTs(ts)}>
            ${timeAgoSafe(ts)}
          </span>
          ${success != null ? html`
            <span class="flex-shrink-0 w-4 ${success ? 'text-[var(--ok)]' : 'text-[var(--bad-light)]'}">
              ${success ? 'O' : 'X'}
            </span>
          ` : html`<span class="w-4"></span>`}
          <span class="font-mono text-[var(--text-strong)] truncate flex-1" title=${entryPreview(entry)}>
            ${entryPreview(entry)}
          </span>
          ${scopeBadges.length > 0 ? html`
            <span class="hidden xl:flex items-center gap-1 flex-shrink-0">
              ${scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-1.5 py-0.5 text-3xs text-[var(--text-dim)] font-mono">${badge}</span>`)}
            </span>
          ` : null}
          <span class="flex-shrink-0 w-4 text-[var(--text-muted)]">${expanded.value ? '-' : '+'}</span>
        </button>
        <span class="mr-2 inline-flex flex-shrink-0">
          <${CopyIdButton}
            value=${rawJson}
            label="telemetry entry JSON"
            ariaLabel="Copy telemetry entry JSON"
            size=${13}
          />
        </span>
      </div>
      ${expanded.value ? html`
        <div class="px-3 pb-3 flex flex-col gap-2">
          ${scopeBadges.length > 0 ? html`
            <div class="flex flex-wrap gap-1.5">
              ${scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-2 py-1 text-3xs text-[var(--text-dim)] font-mono">${badge}</span>`)}
            </div>
          ` : null}
          <div class="rounded bg-[rgba(0,0,0,0.3)] p-2">
            <div class="mb-1.5 flex items-center justify-between gap-2">
              <span class="text-3xs font-medium text-[var(--text-dim)]">Raw JSON</span>
              <${CopyIdButton}
                value=${rawJson}
                label="expanded telemetry entry JSON"
                ariaLabel="Copy expanded telemetry entry JSON"
                size=${13}
              />
            </div>
            <pre class="m-0 text-3xs font-mono text-[var(--text-muted)] overflow-x-auto max-h-75 overflow-y-auto whitespace-pre-wrap break-all">
${rawJson}</pre>
          </div>
        </div>
      ` : null}
    </div>
  `
}

function GroupRow({ item }: { item: Extract<TelemetryDisplayItem, { kind: 'group' }> }) {
  const expanded = useSignal(false)
  const meta = CONDENSED_CATEGORY_META[item.category]
  const latestPreview = entryPreview(item.entries[0] as TelemetryEntry)
  const sourceIcons = uniqueStrings(item.sourceKeys.map(source => sourceMeta(source).icon))
  const contentId = `telemetry-group-${item.key.replace(/[^a-zA-Z0-9_-]/g, '-')}`
  const rawJson = JSON.stringify(item.entries, null, 2)

  return html`
    <div
      class="border-b border-[var(--card-border)] bg-[rgba(255,255,255,0.015)] hover:bg-[var(--bg-panel-hover)] transition-colors"
      style="content-visibility:auto;contain-intrinsic-size:36px"
    >
      <div class="flex items-center gap-1">
        <button
          type="button"
          class="min-w-0 flex-1 flex items-center gap-2 px-3 py-1.5 text-xs cursor-pointer select-none text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent"
          aria-expanded=${expanded.value}
          aria-controls=${contentId}
          onClick=${() => { expanded.value = !expanded.value }}
        >
          <span class="font-mono font-bold ${meta.color} w-4 text-center flex-shrink-0">${meta.icon}</span>
          <span class="font-mono text-[var(--text-muted)] w-28 flex-shrink-0" title=${`${formatTs(item.oldestTs)} → ${formatTs(item.latestTs)}`}>
            ${timeAgoSafe(item.latestTs)}
          </span>
          <span class="flex-shrink-0 w-4 text-[var(--text-dim)]">~</span>
          <span class="font-mono text-[var(--text-strong)] truncate flex-1" title=${`${meta.label} · ${item.label} · ${item.count} events`}>
            ${meta.label} · ${item.label} · ${item.count} events
          </span>
          ${sourceIcons.length > 0 ? html`
            <span class="hidden lg:flex items-center gap-1 flex-shrink-0 text-3xs text-[var(--text-dim)] font-mono">
              ${sourceIcons.join('/')}
            </span>
          ` : null}
          ${item.scopeBadges.length > 0 ? html`
            <span class="hidden xl:flex items-center gap-1 flex-shrink-0">
              ${item.scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-1.5 py-0.5 text-3xs text-[var(--text-dim)] font-mono">${badge}</span>`)}
            </span>
          ` : null}
          <span class="flex-shrink-0 w-4 text-[var(--text-muted)]">${expanded.value ? '-' : '+'}</span>
        </button>
        <span class="mr-2 inline-flex flex-shrink-0">
          <${CopyIdButton}
            value=${rawJson}
            label="telemetry group JSON"
            ariaLabel="Copy telemetry group JSON"
            size=${13}
          />
        </span>
      </div>
      <div id=${contentId} class=${expanded.value ? 'px-3 pb-3 flex flex-col gap-2' : 'hidden'} role="region">
        ${expanded.value ? html`
          <div class="rounded bg-[var(--white-3)] px-2 py-1.5 text-2xs text-[var(--text-dim)]">
            Latest: <span class="font-mono text-[var(--text-strong)]">${latestPreview}</span>
          </div>
          ${item.entries.map((entry, index) => {
            const entryMeta = sourceMeta(entry.source)
            const ts = entryTimestamp(entry)
            return html`
              <div class="flex items-center gap-2 rounded bg-[var(--black-20)] px-2 py-1.5 text-3xs" key=${`${item.key}:${index}`}>
                <span class="font-mono font-bold ${entryMeta.color} w-4 text-center flex-shrink-0">${entryMeta.icon}</span>
                <span class="font-mono text-[var(--text-dim)] w-24 flex-shrink-0" title=${formatTs(ts)}>${timeAgoSafe(ts)}</span>
                <span class="font-mono text-[var(--text-strong)] truncate flex-1" title=${entryPreview(entry)}>${entryPreview(entry)}</span>
              </div>
            `
          })}
          <div class="rounded bg-[var(--black-20)] px-2 py-1.5">
            <div class="flex items-start justify-between gap-2">
              <details class="min-w-0 flex-1">
                <summary class="cursor-pointer text-3xs text-[var(--text-dim)]">Raw JSON</summary>
                <pre class="mt-2 text-3xs font-mono text-[var(--text-muted)] overflow-x-auto max-h-70 overflow-y-auto whitespace-pre-wrap break-all">
${rawJson}</pre>
              </details>
              <${CopyIdButton}
                value=${rawJson}
                label="expanded telemetry group JSON"
                ariaLabel="Copy expanded telemetry group JSON"
                size=${13}
              />
            </div>
          </div>
        ` : null}
      </div>
    </div>
  `
}

export function TelemetryUnified() {
  const params = route.value.params
  const latestRequestId = useRef(0)
  const activeController = useRef<AbortController | null>(null)
  const initialLoadDone = useRef(false)
  const autoRefreshLoadRef = useRef<() => Promise<void>>(async () => undefined)
  const state = useSignal<TelemetryState>({
    entries: [],
    summary: [],
    totalEntries: 0,
    store: EMPTY_STORE,
    loading: true,
    error: null,
  })
  const sourceFilter = useSignal<TelemetrySource | ''>('')
  const keeperFilter = useSignal('')
  const sessionFilter = useSignal(params.session_id ?? '')
  const operationFilter = useSignal(params.operation_id ?? '')
  const workerRunFilter = useSignal(params.worker_run_id ?? '')
  const limit = useSignal(100)
  const entrySearch = useSignal('')

  useEffect(() => {
    sessionFilter.value = route.value.params.session_id ?? ''
    operationFilter.value = route.value.params.operation_id ?? ''
    workerRunFilter.value = route.value.params.worker_run_id ?? ''
  }, [
    route.value.params.session_id,
    route.value.params.operation_id,
    route.value.params.worker_run_id,
  ])

  async function load() {
    activeController.current?.abort()
    const controller = new AbortController()
    activeController.current = controller
    const requestId = ++latestRequestId.current
    state.value = { ...state.value, loading: true, error: null }
    try {
      const catchStoreFailure = <T,>(promise: Promise<T>) =>
        promise.catch(error => {
          if (isAbortError(error)) throw error
          return null
        })
      const storePromise = Promise.all([
        catchStoreFailure(fetchDashboardShell({ light: true, signal: controller.signal })),
        catchStoreFailure(fetchDashboardTools({ signal: controller.signal })),
        catchStoreFailure(fetchDashboardNamespaceTruth({ signal: controller.signal })),
      ]).then(([shell, tools, truth]) => {
        const counts = shell?.counts
        const execSummary = truth?.execution?.summary
        const inv = tools?.tool_inventory
        const usage = tools?.tool_usage
        const surfacePublic = inv?.surface_summary?.public_mcp?.count ?? inv?.surface_summary?.public?.count ?? 0
        return {
          keepers: counts?.keepers ?? 0,
          agents: counts?.agents ?? 0,
          tasks: counts?.tasks ?? 0,
          activeOperations: execSummary?.active_operations ?? 0,
          blockedOperations: execSummary?.blocked_operations ?? 0,
          continuityAlerts: execSummary?.continuity_alerts ?? 0,
          toolsRegistered: inv?.count ?? 0,
          toolsPublic: surfacePublic,
          toolsTotalCalls: usage?.total_calls ?? 0,
          toolsNeverCalled: usage?.never_called_count ?? 0,
          version: shell?.status?.version ?? null,
          uptime: shell?.status?.build?.uptime_seconds ?? null,
        } satisfies StoreSnapshot
      })
      const [telemetry, , store] = await Promise.all([
        fetchTelemetry({
          source: sourceFilter.value || undefined,
          keeper: keeperFilter.value || undefined,
          session_id: sessionFilter.value || undefined,
          operation_id: operationFilter.value || undefined,
          worker_run_id: workerRunFilter.value || undefined,
          n: limit.value,
          signal: controller.signal,
        }),
        // Summary is shared via fleet-data-core so Phase 2's fleet-health view
        // does not duplicate this fetch across panels.
        refreshSharedTelemetrySummary({ signal: controller.signal }),
        storePromise,
      ])
      if (requestId !== latestRequestId.current) return
      // refreshSharedTelemetrySummary records failures on the shared error
      // signal rather than throwing (so tool-quality-panel can keep rendering
      // the last-good value). Telemetry-unified, however, treated a summary
      // failure as a panel-level error before Phase 0, so re-raise it here
      // to preserve the user-visible regression surface.
      const summaryError = sharedTelemetrySummaryError.value
      if (summaryError !== null) {
        throw new Error(summaryError)
      }
      const summary = sharedTelemetrySummary.value ?? { sources: [], total_entries: 0, generated_at: '' }
      state.value = {
        entries: telemetry.entries,
        summary: summary.sources,
        totalEntries: summary.total_entries,
        store,
        loading: false,
        error: null,
      }
    } catch (e) {
      if (isAbortError(e) || requestId !== latestRequestId.current) return
      state.value = {
        ...state.value,
        loading: false,
        error: e instanceof Error ? e.message : String(e),
      }
    } finally {
      if (activeController.current === controller) {
        activeController.current = null
      }
    }
  }
  autoRefreshLoadRef.current = load

  useEffect(() => {
    if (!initialLoadDone.current) {
      initialLoadDone.current = true
      void autoRefreshLoadRef.current()
      return
    }
    const timeoutId = window.setTimeout(() => {
      void autoRefreshLoadRef.current()
    }, 250)
    return () => {
      window.clearTimeout(timeoutId)
    }
  }, [
    sourceFilter.value,
    keeperFilter.value,
    sessionFilter.value,
    operationFilter.value,
    workerRunFilter.value,
    limit.value,
  ])

  useEffect(() => {
    const disposeAutoRefresh = setupVisibleAutoRefresh(() => autoRefreshLoadRef.current(), TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
      activeController.current?.abort()
      activeController.current = null
    }
  }, [])

  const { entries, summary, totalEntries, store, loading, error } = state.value
  const entrySearchQuery = entrySearch.value
  const allDisplayItems = useMemo(() => buildTelemetryDisplayItems(entries), [entries])
  const displayItems = useMemo(
    () => filterTelemetryDisplayItems(allDisplayItems, entrySearchQuery),
    [allDisplayItems, entrySearchQuery],
  )
  const isFilteringEntries = entrySearchQuery.trim() !== ''
  const condensed = useMemo(() => condensedStats(displayItems), [displayItems])

  return html`
    <div class="flex flex-col gap-4">
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-4">
        <div class="text-xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">Runtime Diagnosis</div>
        <div class="mt-1 text-base leading-relaxed text-[var(--text-body)]">
          MASC telemetry store (keeper/tool/agent) 진단 뷰.
        </div>
        <div class="mt-3 flex flex-wrap gap-2">
          <span class="rounded bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-dim)]">MASC: keeper/tool/agent store</span>
          ${sessionFilter.value ? html`<span class="rounded bg-[var(--white-4)] px-2 py-1 text-2xs font-mono text-[var(--text-dim)]">session ${sessionFilter.value}</span>` : null}
          ${operationFilter.value ? html`<span class="rounded bg-[var(--white-4)] px-2 py-1 text-2xs font-mono text-[var(--text-dim)]">operation ${operationFilter.value}</span>` : null}
          ${workerRunFilter.value ? html`<span class="rounded bg-[var(--white-4)] px-2 py-1 text-2xs font-mono text-[var(--text-dim)]">worker_run ${workerRunFilter.value}</span>` : null}
        </div>
      </div>

      <${OasHealthChip} />

      <div class="flex flex-wrap gap-3">
        ${summary.map(src => html`<${SummaryCard} src=${src} />`)}
        <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3 min-w-35">
          <div class="text-xs font-medium text-[var(--text-muted)] mb-1">전체</div>
          <div class="text-2xl font-bold text-[var(--text-strong)]">${totalEntries.toLocaleString()}</div>
        </div>
      </div>

      <div class="flex flex-wrap gap-3">
        <${DiagnosisCard}
          title="Keeper 현황 (live)"
          value=${String(store.keepers)}
          detail=${[
            `${store.activeOperations} 활성 작업`,
            store.blockedOperations > 0 ? `${store.blockedOperations} 차단 작업` : null,
            `${store.continuityAlerts} continuity 알림`,
            store.version ? `v${store.version}` : null,
            store.uptime != null ? `uptime ${Math.floor(store.uptime / 60)}m` : null,
          ].filter(Boolean).join(' · ')}
          tone=${store.continuityAlerts > 0 ? 'warn' : store.keepers > 0 ? 'ok' : 'neutral'}
        />
        <${DiagnosisCard}
          title="Tool 등록 현황 (live)"
          value=${String(store.toolsRegistered)}
          detail=${`${store.toolsPublic} public · ${store.toolsTotalCalls.toLocaleString()} 총 호출 · ${store.toolsNeverCalled} 미사용`}
          tone=${store.toolsRegistered > 0 ? 'ok' : 'warn'}
        />
        <${DiagnosisCard}
          title="Agent 현황 (live)"
          value=${String(store.agents)}
          detail=${`${store.tasks} 태스크 · ${store.activeOperations} 활성 작전`}
          tone=${store.agents > 0 ? 'ok' : 'neutral'}
        />
      </div>

      <div class="flex items-center gap-3 flex-wrap">
        <select
          aria-label="텔레메트리 소스 필터"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${sourceFilter.value}
          onChange=${(e: Event) => { sourceFilter.value = (e.target as HTMLSelectElement).value as TelemetrySource | '' }}
        >
          <option value="">전체 소스</option>
          ${Object.entries(TELEMETRY_SOURCE_META).map(([key, m]) => html`<option value=${key}>${m.label}</option>`)}
        </select>
        <input
          type="text"
          placeholder="키퍼 이름..."
          aria-label="키퍼 이름 필터"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-32"
          value=${keeperFilter.value}
          onInput=${(e: Event) => { keeperFilter.value = (e.target as HTMLInputElement).value }}
        />
        <input
          type="text"
          placeholder="session_id"
          aria-label="session_id 필터"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${sessionFilter.value}
          onInput=${(e: Event) => { sessionFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="operation_id"
          aria-label="operation_id 필터"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${operationFilter.value}
          onInput=${(e: Event) => { operationFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="worker_run_id"
          aria-label="worker_run_id 필터"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${workerRunFilter.value}
          onInput=${(e: Event) => { workerRunFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="search"
          placeholder="엔트리 검색..."
          aria-label="엔트리 텍스트 검색"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-48"
          value=${entrySearch.value}
          onInput=${(e: Event) => { entrySearch.value = (e.target as HTMLInputElement).value }}
        />
        <select
          aria-label="표시 개수 제한"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${String(limit.value)}
          onChange=${(e: Event) => { limit.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="50">50</option>
          <option value="100">100</option>
          <option value="200">200</option>
          <option value="500">500</option>
        </select>
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void load()}
        >
          Refresh
        </button>
        <span class="text-xs text-[var(--text-muted)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        ${loading ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>` : null}
      </div>

      ${error ? html`
        <div class="rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-xs text-[var(--bad-light)]">
          ${error}
        </div>
      ` : null}

      <div class="rounded border border-[var(--card-border)] overflow-hidden">
        <div class="px-3 py-2 border-b border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-muted)]">
          MASC telemetry store entries ${entries.length.toLocaleString()}건
          ${isFilteringEntries
            ? ` · 검색 매치 ${displayItems.length.toLocaleString()}건`
            : ''}
          ${condensed.groups > 0
            ? ` · 반복 그룹 ${condensed.groups.toLocaleString()}개 · 원본 ${condensed.groupedEntries.toLocaleString()}건`
            : ''}
        </div>
        ${condensed.groups > 0 ? html`
          <div class="px-3 py-2 border-b border-[var(--card-border)] bg-[var(--white-1)] flex flex-wrap gap-2 text-2xs">
            ${Array.from(condensed.byCategory.entries()).map(([category, count]) => {
              const meta = CONDENSED_CATEGORY_META[category]
              return html`
                <span class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-2 py-1 text-[var(--text-dim)]">
                  <span class="font-mono ${meta.color}">${meta.icon}</span>
                  <span class="ml-1">${meta.label}</span>
                  <span class="ml-1 font-mono">${count}</span>
                </span>
              `
            })}
          </div>
        ` : null}
        <div class="max-h-150 overflow-y-auto">
          ${displayItems.length > 0
            ? displayItems.map(item => item.kind === 'group'
              ? html`<${GroupRow} key=${item.key} item=${item} />`
              : html`<${EntryRow} key=${item.key} entry=${item.entry} />`)
            : isFilteringEntries && allDisplayItems.length > 0
              ? html`<div class="px-4 py-6 text-sm text-[var(--text-muted)]">필터 결과 없음 (${allDisplayItems.length} items)</div>`
              : html`<div class="px-4 py-6 text-sm text-[var(--text-muted)]">선택한 scope에 해당하는 MASC telemetry entry가 없습니다.</div>`}
        </div>
      </div>
    </div>
  `
}

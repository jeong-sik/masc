// Telemetry Unified — MASC runtime diagnosis view.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchDashboardShell,
  fetchDashboardTools,
  fetchDashboardNamespaceTruth,
  fetchDashboardCacheStats,
  fetchTelemetry,
  type DashboardCacheStatsResponse,
  type TelemetryEntry,
  type TelemetryResponse,
  type TelemetrySource,
  type TelemetrySourceSummary,
} from '../api/dashboard'
import {
  refreshSharedTelemetrySummary,
  sharedTelemetrySummary,
  sharedTelemetrySummaryError,
} from './fleet-data-core'
import { replaceRoute, route } from '../router'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { TELEMETRY_SOURCE_META, telemetrySourceMeta } from '../config/telemetry-sources'
import { formatElapsedCompact, unixSecondsToDate } from '../lib/format-time'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { isAbortError } from '../lib/async-state'
import { errorToString } from '../lib/format-string'
import { Btn } from './btn'
import { OasHealthChip } from './oas-health-chip'
import { CopyIdButton } from './common/copy-id-button'
import { ringFocusClasses } from './common/ring'
import { StatTile } from './common/stat-tile'
import { coverageGapDisplay } from './common/source-health'
import { TimeAgo } from './common/time-ago'
import { asNullableString, asRecord, asStringArray } from './common/normalize'

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
  telemetry: TelemetryResponse | null
  summary: TelemetrySourceSummary[]
  totalEntries: number
  store: StoreSnapshot
  cacheStats: DashboardCacheStatsResponse | null
  cacheStatsError: string | null
  loading: boolean
  error: string | null
}

const sourceMeta = telemetrySourceMeta

type TelemetryCondensedCategory = 'heartbeat' | 'polling' | 'turn'

interface TelemetryRouteFocus {
  readonly sessionId: string | null
  readonly operationId: string | null
  readonly workerRunId: string | null
  readonly query: string | null
}

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
    label: '하트비트',
    icon: 'H',
    color: 'text-[var(--color-accent-fg)]',
  },
  polling: {
    label: '폴링 / 무동작',
    icon: 'P',
    color: 'text-[var(--color-accent-fg)]',
  },
  turn: {
    label: '턴',
    icon: 'T',
    color: 'text-[var(--color-accent-fg)]',
  },
}

const NOISY_TOOL_NAMES = new Set([
  'masc_status',
  'masc_tasks',
  'masc_messages',
  'masc_agents',
  'keeper_tasks_list',
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
  const d = unixSecondsToDate(ts)
  return d.toLocaleString('ko-KR', {
    month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function recordField(value: unknown, key: string): unknown {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  return (value as Record<string, unknown>)[key]
}

function normalizeNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function telemetrySourceFromRouteParam(value: unknown): TelemetrySource | '' {
  const source = asNullableString(value)
  return source && source in TELEMETRY_SOURCE_META ? (source as TelemetrySource) : ''
}

function telemetryLimitFromRouteParam(value: unknown): number {
  const parsed = normalizeNumber(value)
  return parsed != null && [50, 100, 200, 500].includes(parsed) ? parsed : 100
}

function uniqueStrings(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const normalized = asNullableString(value)
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
    compactId(asNullableString(entry.session_id), 'S'),
    compactId(asNullableString(entry.operation_id), 'OP'),
    compactId(asNullableString(entry.worker_run_id), 'WR'),
  ].filter((value): value is string => Boolean(value))
}

function telemetryRouteFocusFromParams(
  params: Record<string, string | undefined>,
): TelemetryRouteFocus | null {
  const focus = {
    sessionId: asNullableString(params.session_id),
    operationId: asNullableString(params.operation_id),
    workerRunId: asNullableString(params.worker_run_id),
    query: asNullableString(params.q),
  }
  return focus.sessionId || focus.operationId || focus.workerRunId || focus.query
    ? focus
    : null
}

function clearTelemetryRouteFocus(): void {
  const params: Record<string, string> = {
    ...route.value.params,
    section: 'fleet-health',
    view: 'event-log',
  }
  delete params.session_id
  delete params.operation_id
  delete params.worker_run_id
  delete params.q
  replaceRoute('monitoring', params)
}

function telemetryRouteFocusBadges(focus: TelemetryRouteFocus): ReadonlyArray<{ readonly label: string; readonly value: string }> {
  return [
    focus.sessionId ? { label: 'SESSION', value: focus.sessionId } : null,
    focus.operationId ? { label: 'OPERATION', value: focus.operationId } : null,
    focus.workerRunId ? { label: 'WORKER', value: focus.workerRunId } : null,
    focus.query ? { label: 'QUERY', value: focus.query } : null,
  ].filter((value): value is { readonly label: string; readonly value: string } => value !== null)
}

function telemetryToolName(entry: TelemetryEntry): string | null {
  if (entry.source === 'tool_call_io') return asNullableString(entry.tool)
  if (entry.source === 'tool_usage' || entry.source === 'tool_metric' || entry.source === 'trajectory_tool_call') {
    return asNullableString(entry.tool_name)
      ?? asNullableString(recordField(entry.action_radius, 'tool_name'))
  }
  if (entry.source === 'execution_receipt') {
    return asStringArray(entry.canonical_tools)[0]
      ?? asNullableString(recordField(entry.action_radius, 'tool_name'))
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
    return asNullableString(tool ?? value)
  }
  return asNullableString(value)
}

function telemetryPayloadRecord(entry: TelemetryEntry): Record<string, unknown> | null {
  const direct = asRecord(entry.payload)
  if (direct) return direct
  if (Array.isArray(entry.payload)) {
    return asRecord(entry.payload[1])
  }
  return null
}

function telemetryPayloadKind(entry: TelemetryEntry): string | null {
  if (Array.isArray(entry.payload)) return asNullableString(entry.payload[0])
  return asNullableString(recordField(entry.payload, 'kind'))
    ?? asNullableString(recordField(entry.payload, 'event_type'))
}

function telemetryPayloadProviderParts(entry: TelemetryEntry): string[] {
  const payload = telemetryPayloadRecord(entry)
  if (!payload) return []
  return uniqueStrings([
    asNullableString(recordField(payload, 'provider_kind')),
    asNullableString(recordField(payload, 'provider')),
    asNullableString(recordField(payload, 'model_id')),
    asNullableString(recordField(payload, 'provider_model_id')),
    asNullableString(recordField(payload, 'model')),
    asNullableString(recordField(payload, 'base_url')),
    asNullableString(recordField(payload, 'endpoint')),
  ])
}

function compactTelemetryPayloadSearch(entry: TelemetryEntry): string {
  const payload = entry.payload
  if (payload == null) return ''
  try {
    return JSON.stringify(payload).slice(0, 4096)
  } catch {
    return ''
  }
}

function telemetryTurn(entry: TelemetryEntry): number | null {
  return normalizeNumber(entry.turn)
    ?? normalizeNumber(recordField(telemetryPayloadRecord(entry), 'turn'))
    ?? normalizeNumber(recordField(entry.runtime_contract, 'turn'))
}

function telemetryTurnActor(entry: TelemetryEntry): string | null {
  const payload = telemetryPayloadRecord(entry)
  return asNullableString(entry.agent_name)
    ?? asNullableString(recordField(payload, 'agent_name'))
    ?? asNullableString(recordField(entry.runtime_contract, 'agent_name'))
    ?? asNullableString(entry.keeper_name)
    ?? asNullableString(recordField(entry.runtime_contract, 'keeper_name'))
    ?? asNullableString(entry.keeper)
    ?? asNullableString(entry.name)
    ?? asNullableString(entry.caller)
    ?? asNullableString(entry.agent)
}

function telemetryRunScope(entry: TelemetryEntry): string | null {
  const payload = telemetryPayloadRecord(entry)
  const session =
    asNullableString(entry.session_id)
    ?? asNullableString(recordField(payload, 'session_id'))
    ?? asNullableString(recordField(entry.runtime_contract, 'session_id'))
  if (session) return `S:${session}`
  const operation =
    asNullableString(entry.operation_id)
    ?? asNullableString(recordField(payload, 'operation_id'))
    ?? asNullableString(recordField(entry.runtime_contract, 'operation_id'))
  if (operation) return `OP:${operation}`
  const workerRun =
    asNullableString(entry.worker_run_id)
    ?? asNullableString(recordField(payload, 'worker_run_id'))
    ?? asNullableString(recordField(entry.runtime_contract, 'worker_run_id'))
  if (workerRun) return `WR:${workerRun}`
  return null
}

function entryTurnGroupingDescriptor(entry: TelemetryEntry): {
  key: string
  category: TelemetryCondensedCategory
  label: string
} | null {
  const turn = telemetryTurn(entry)
  const actor = telemetryTurnActor(entry)
  // turn=0 is a "turn not tracked" marker in keeper telemetry (e.g.,
  // trajectory tool-call records); collapsing on it would merge unrelated
  // events into a fake `actor · turn 0` group. Only group on real turn ids
  // (positive integers).
  if (turn == null || turn <= 0 || !actor) return null
  const runScope = telemetryRunScope(entry)
  const scopedKey = runScope ? `turn:${runScope}:${actor}:${turn}` : `turn:${actor}:${turn}`
  return {
    key: scopedKey,
    category: 'turn',
    label: `${actor} · turn ${turn}`,
  }
}

/** Per-keeper polling artifacts that fill the 100-entry window with no
 *  per-event signal: keeper_metric/heartbeat snapshots and the matching
 *  oas_event/masc:keeper:{snapshot,lifecycle} relays. We classify them as
 *  one fleet-wide "heartbeat" category so all instances collapse into a
 *  single group regardless of (a) which keeper emitted it or
 *  (b) whether they are consecutive in the stream — see #13002 for the
 *  before/after screenshot. */
const FLEET_POLLING_OAS_EVENT_TYPES = new Set([
  'masc:keeper:snapshot',
  'masc:keeper:lifecycle',
  'oas:masc:keeper:snapshot',
  'oas:masc:keeper:lifecycle',
])

function isFleetPollingEntry(entry: TelemetryEntry): boolean {
  if (entry.source === 'keeper_metric' && asNullableString(entry.channel) === 'heartbeat') {
    return true
  }
  if (entry.source === 'oas_event') {
    const eventType = asNullableString(entry.event_type) ?? asNullableString(entry.type)
    if (eventType != null && FLEET_POLLING_OAS_EVENT_TYPES.has(eventType)) return true
  }
  return false
}

function entryGroupingDescriptor(entry: TelemetryEntry): {
  key: string
  category: TelemetryCondensedCategory
  label: string
} | null {
  if (isFleetPollingEntry(entry)) {
    return {
      // Fleet-wide single key so ALL polling artifacts (heartbeat + snapshot
      // + lifecycle, across every keeper) merge into one group regardless of
      // arrival order.
      key: 'heartbeat:fleet',
      category: 'heartbeat',
      label: 'fleet heartbeat',
    }
  }

  const turnDescriptor = entryTurnGroupingDescriptor(entry)
  if (turnDescriptor) return turnDescriptor

  const tool = canonicalToolName(telemetryToolName(entry))
  if (!tool || !NOISY_TOOL_NAMES.has(tool)) return null

  const scope =
    asNullableString(entry.session_id)
    ?? asNullableString(entry.operation_id)
    ?? asNullableString(entry.worker_run_id)
    ?? asNullableString(entry.keeper)
    ?? asNullableString(entry.keeper_name)
    ?? asNullableString(entry.name)
    ?? asNullableString(entry.caller)
    ?? asNullableString(entry.agent_name)
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
      const name = asNullableString(e.name) ?? '-'
      const channel = asNullableString(e.channel) ?? '-'
      const tools = asStringArray(e.tools_used)
      const toolCount = typeof e.tool_call_count === 'number' ? e.tool_call_count : tools.length
      return `${name} [${channel}] tools=${toolCount}`
    }
    case 'agent_event': {
      const event = e.event
      if (Array.isArray(event)) {
        const tag = String(event[0] ?? 'unknown')
        const detail = event[1] as Record<string, unknown> | undefined
        if (detail) {
          const parts = [
            asNullableString(detail.agent_id as string),
            asNullableString(detail.tool_name as string),
          ].filter(Boolean)
          return parts.length > 0 ? `${tag}: ${parts.join(' -> ')}` : tag
        }
        return tag
      }
      return String(event ?? '')
    }
    case 'tool_call_io': {
      const tool = asNullableString(e.tool) ?? ''
      const keeper = asNullableString(e.keeper) ?? ''
      return `${keeper} -> ${tool}`
    }
    case 'trajectory_tool_call': {
      const tool = telemetryToolName(e) ?? '(unknown tool)'
      const keeper =
        asNullableString(e.keeper_name)
        ?? asNullableString(recordField(e.runtime_contract, 'keeper_name'))
        ?? asNullableString(e.keeper)
        ?? '(unknown keeper)'
      return `${keeper} -> ${tool}`
    }
    case 'tool_usage': {
      const tool = asNullableString(e.tool_name) ?? ''
      const caller = asNullableString(e.caller) ?? ''
      return `${caller || 'unknown'} -> ${tool}`
    }
    case 'oas_event': {
      const eventType = asNullableString(e.event_type) ?? asNullableString(e.type) ?? '(unknown event_type)'
      const payloadKind = telemetryPayloadKind(e)
      const agentName = telemetryTurnActor(e)
      const toolName = asNullableString(e.tool_name) ?? asNullableString(recordField(telemetryPayloadRecord(e), 'tool_name'))
      const turn = telemetryTurn(e)
      const taskId = asNullableString(e.task_id)
      const parts = [
        payloadKind,
        agentName,
        toolName,
        turn != null ? `turn ${turn}` : null,
        taskId,
        ...telemetryPayloadProviderParts(e),
      ].filter(Boolean)
      return parts.length > 0 ? `${eventType}: ${parts.join(' · ')}` : eventType
    }
    case 'execution_receipt': {
      const keeper = asNullableString(e.keeper_name) ?? asNullableString(e.agent_name) ?? '(unknown keeper)'
      const outcome = asNullableString(e.outcome) ?? asNullableString(e.operator_disposition) ?? '(no outcome)'
      const reason = asNullableString(e.terminal_reason_code)
      return reason ? `${keeper} receipt ${outcome} (${reason})` : `${keeper} receipt ${outcome}`
    }
    case 'tool_metric': {
      const tool = asNullableString(e.tool_name) ?? ''
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

  return items.filter(item => telemetryDisplayItemHaystack(item).toLowerCase().includes(needle))
}

function telemetryEntryHaystack(entry: TelemetryEntry): string {
  const source = typeof entry.source === 'string' ? entry.source : ''
  const preview = entryPreview(entry)
  const badges = telemetryScopeBadges(entry).join(' ')
  const payload = entry.source === 'oas_event' ? compactTelemetryPayloadSearch(entry) : ''
  return `${source} ${preview} ${badges} ${payload}`
}

function telemetryDisplayItemHaystack(item: TelemetryDisplayItem): string {
  if (item.kind === 'entry') return telemetryEntryHaystack(item.entry)
  const sources = item.sourceKeys.join(' ')
  const badges = item.scopeBadges.join(' ')
  const previews = item.entries.map(entry => entryPreview(entry)).join(' ')
  return `${sources} ${item.label} ${badges} ${previews}`
}

function telemetryEntryMatchesRouteFocus(entry: TelemetryEntry, focus: TelemetryRouteFocus): boolean {
  if (focus.sessionId && asNullableString(entry.session_id) !== focus.sessionId) return false
  if (focus.operationId && asNullableString(entry.operation_id) !== focus.operationId) return false
  if (focus.workerRunId && asNullableString(entry.worker_run_id) !== focus.workerRunId) return false
  if (focus.query && !telemetryEntryHaystack(entry).toLowerCase().includes(focus.query.toLowerCase())) return false
  return true
}

function telemetryDisplayItemMatchesRouteFocus(item: TelemetryDisplayItem, focus: TelemetryRouteFocus): boolean {
  if (item.kind === 'entry') return telemetryEntryMatchesRouteFocus(item.entry, focus)
  return item.entries.some(entry => telemetryEntryMatchesRouteFocus(entry, focus))
}

export function buildTelemetryDisplayItems(entries: TelemetryEntry[]): TelemetryDisplayItem[] {
  const items: TelemetryDisplayItem[] = []
  let nextItemId = 0

  type ActiveGroup = {
    key: string
    category: TelemetryCondensedCategory
    label: string
    entries: TelemetryEntry[]
    latestTs: number
    oldestTs: number
    sourceKeys: Set<TelemetrySource>
    scopeBadges: string[]
  }

  let activeGroup: ActiveGroup | null = null
  const persistentGroups = new Map<string, ActiveGroup>()

  const renderGroup = (g: ActiveGroup): TelemetryDisplayItem => {
    if (g.entries.length === 1) {
      const entry = g.entries[0] as TelemetryEntry
      const item: TelemetryDisplayItem = {
        kind: 'entry',
        key: `${g.key}:${g.latestTs}:${nextItemId}`,
        entry,
      }
      nextItemId += 1
      return item
    }
    const item: TelemetryDisplayItem = {
      kind: 'group',
      key: `${g.key}:${g.latestTs}:${g.entries.length}:${nextItemId}`,
      category: g.category,
      label: g.label,
      count: g.entries.length,
      latestTs: g.latestTs,
      oldestTs: g.oldestTs,
      entries: g.entries,
      sourceKeys: Array.from(g.sourceKeys),
      scopeBadges: g.scopeBadges,
    }
    nextItemId += 1
    return item
  }

  const flushGroup = () => {
    if (!activeGroup) return
    items.push(renderGroup(activeGroup))
    activeGroup = null
  }

  const accumulate = (target: ActiveGroup, entry: TelemetryEntry, ts: number) => {
    target.entries.push(entry)
    if (target.latestTs === 0 && ts !== 0) target.latestTs = ts
    else if (ts !== 0) target.latestTs = Math.max(target.latestTs, ts)
    if (target.oldestTs === 0) target.oldestTs = ts
    else if (ts !== 0) target.oldestTs = Math.min(target.oldestTs, ts)
    target.sourceKeys.add(entry.source)
    target.scopeBadges = uniqueStrings([
      ...target.scopeBadges,
      ...telemetryScopeBadges(entry),
    ])
  }

  // Heartbeat and turn groups are causal groups, not just adjacent noisy rows.
  // Build them up front so interleaved rows still collapse at first occurrence.
  for (const entry of entries) {
    const descriptor = entryGroupingDescriptor(entry)
    if (!descriptor || (descriptor.key !== 'heartbeat:fleet' && descriptor.category !== 'turn')) {
      continue
    }
    const ts = entryTimestamp(entry)
    const existing = persistentGroups.get(descriptor.key)
    if (existing) {
      accumulate(existing, entry, ts)
    } else {
      persistentGroups.set(descriptor.key, {
        key: descriptor.key,
        category: descriptor.category,
        label: descriptor.label,
        entries: [entry],
        latestTs: ts,
        oldestTs: ts,
        sourceKeys: new Set([entry.source]),
        scopeBadges: telemetryScopeBadges(entry),
      })
    }
  }

  const emittedPersistentGroups = new Set<string>()

  for (const entry of entries) {
    const descriptor = entryGroupingDescriptor(entry)
    const ts = entryTimestamp(entry)

    if (descriptor && persistentGroups.has(descriptor.key)) {
      flushGroup()
      if (!emittedPersistentGroups.has(descriptor.key)) {
        const group = persistentGroups.get(descriptor.key) as ActiveGroup
        items.push(renderGroup(group))
        emittedPersistentGroups.add(descriptor.key)
      }
      continue
    }

    if (!descriptor) {
      flushGroup()
      items.push({
        kind: 'entry',
        key: `${entry.source}:${ts}:${nextItemId}`,
        entry,
      })
      nextItemId += 1
      continue
    }

    if (activeGroup && activeGroup.key === descriptor.key) {
      accumulate(activeGroup, entry, ts)
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
  const byCategory = new Map<TelemetryCondensedCategory, number>()
  for (const item of items) {
    if (item.kind !== 'group') continue
    groups += 1
    groupedEntries += item.count
    byCategory.set(item.category, (byCategory.get(item.category) ?? 0) + item.count)
  }
  return { groups, groupedEntries, byCategory }
}

function telemetrySourceStatusParts(src: TelemetrySourceSummary): string[] {
  const parts: string[] = []
  const coverageGap = coverageGapDisplay(src)
  if (src.health) {
    parts.push(src.stale_reason ? `${src.health}: ${src.stale_reason}` : src.health)
  } else if (src.stale_reason) {
    parts.push(src.stale_reason)
  }
  if (coverageGap) {
    parts.push(coverageGap.summary)
  }
  if (typeof src.latest_age_s === 'number' && Number.isFinite(src.latest_age_s)) {
    parts.push(`age ${formatElapsedCompact(src.latest_age_s)}`)
  }
  if (typeof src.freshness_slo_s === 'number' && Number.isFinite(src.freshness_slo_s)) {
    parts.push(`SLO ${formatElapsedCompact(src.freshness_slo_s)}`)
  }
  return parts
}

function telemetrySourceProvenanceRows(src: TelemetrySourceSummary): Array<{ label: string; value: string }> {
  const rows: Array<{ label: string; value: string }> = []
  if (src.producer) rows.push({ label: 'producer', value: src.producer })
  if (src.durable_store) rows.push({ label: 'store', value: src.durable_store })
  if (src.dashboard_surface) rows.push({ label: 'surface', value: src.dashboard_surface })
  const coverageGap = coverageGapDisplay(src)
  for (const detail of coverageGap?.details ?? []) {
    const separator = detail.indexOf(' ')
    if (separator <= 0) {
      rows.push({ label: 'gap', value: detail })
    } else {
      rows.push({
        label: `gap ${detail.slice(0, separator)}`,
        value: detail.slice(separator + 1),
      })
    }
  }
  return rows
}

function formatMilliseconds(value: number | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-'
  const abs = Math.abs(value)
  if (abs >= 1000) return `${(value / 1000).toFixed(1)}s`
  return `${value}ms`
}

function shortCacheKey(key: string): string {
  const withoutPrefix = key.startsWith('telemetry:') ? key.slice('telemetry:'.length) : key
  return withoutPrefix.length > 90 ? `...${withoutPrefix.slice(-87)}` : withoutPrefix
}

function TelemetryCachePanel({
  telemetry,
  summary,
  cacheStats,
  cacheStatsError,
}: {
  telemetry: TelemetryResponse | null
  summary: TelemetrySourceSummary[]
  cacheStats: DashboardCacheStatsResponse | null
  cacheStatsError: string | null
}) {
  const telemetryCacheEntries = (cacheStats?.entry_details ?? []).filter(entry => entry.key.startsWith('telemetry:'))
  const cacheKindCounts = telemetryCacheEntries.reduce<Record<string, number>>((acc, entry) => {
    acc[entry.kind] = (acc[entry.kind] ?? 0) + 1
    return acc
  }, {})
  const unhealthySources = summary.filter(src => {
    const health = src.health ?? ''
    return health !== '' && health !== 'ok' && health !== 'healthy' && health !== 'fresh'
  })
  const activeQuery = telemetry?.query
  const queryParts = [
    activeQuery?.source ? `source=${String(activeQuery.source)}` : null,
    activeQuery?.keeper ? `keeper=${String(activeQuery.keeper)}` : null,
    activeQuery?.session_id ? `session=${String(activeQuery.session_id)}` : null,
    activeQuery?.operation_id ? `operation=${String(activeQuery.operation_id)}` : null,
    activeQuery?.worker_run_id ? `worker=${String(activeQuery.worker_run_id)}` : null,
    activeQuery?.n ? `n=${String(activeQuery.n)}` : null,
  ].filter((part): part is string => Boolean(part))
  const cacheRows = telemetryCacheEntries.slice(0, 3)
  return html`
    <section class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" aria-label="Telemetry cache freshness">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">Query cache</div>
          <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
            ${telemetry?.generated_at_iso ?? telemetry?.generated_at ?? '-'}
            ${telemetry?.dashboard_surface ? html`<span class="mx-1">·</span><span class="font-mono">${telemetry.dashboard_surface}</span>` : null}
          </div>
        </div>
        <div class="flex flex-wrap gap-2 text-2xs">
          <span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-muted)]">
            telemetry keys <span class="font-mono text-[var(--color-fg-primary)]">${telemetryCacheEntries.length}</span>
          </span>
          <span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-muted)]">
            hit <span class="font-mono text-[var(--color-fg-primary)]">${(((cacheStats?.hit_ratio ?? 0) * 100).toFixed(0))}%</span>
          </span>
          <span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-muted)]">
            source issues <span class=${`font-mono ${unhealthySources.length > 0 ? 'text-[var(--bad-light)]' : 'text-[var(--color-status-ok)]'}`}>${unhealthySources.length}</span>
          </span>
        </div>
      </div>
      <div class="mt-3 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
        <div class="grid gap-2 text-2xs text-[var(--color-fg-muted)]">
          <div class="flex flex-wrap gap-2">
            ${Object.entries(cacheKindCounts).length > 0
              ? Object.entries(cacheKindCounts).map(([kind, count]) => html`
                <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2 py-1 font-mono">${kind}:${count}</span>
              `)
              : html`<span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2 py-1">no telemetry cache rows</span>`}
          </div>
          ${cacheStatsError ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--bad-muted)] bg-[var(--bad-soft)] px-2 py-1 text-[var(--bad-light)]">
              cache stats unavailable: ${cacheStatsError}
            </div>
          ` : null}
          ${queryParts.length > 0 ? html`
            <div class="min-w-0 break-all font-mono text-3xs text-[var(--color-fg-disabled)]">${queryParts.join(' · ')}</div>
          ` : null}
        </div>
        <div class="grid gap-1">
          ${cacheRows.length > 0 ? cacheRows.map(entry => html`
            <div class="grid grid-cols-[5.5rem_minmax(0,1fr)_7rem] items-center gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs">
              <span class="font-mono text-[var(--color-fg-muted)]">${entry.kind}</span>
              <span class="min-w-0 truncate font-mono text-[var(--color-fg-primary)]" title=${entry.key}>${shortCacheKey(entry.key)}</span>
              <span class="text-right font-mono text-[var(--color-fg-disabled)]">
                ${entry.kind === 'computing'
                  ? formatMilliseconds(entry.computing_for_ms)
                  : formatMilliseconds(entry.ttl_remaining_ms)}
              </span>
            </div>
          `) : html`
            <div class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs text-[var(--color-fg-disabled)]">
              cache detail sample does not include telemetry rows
            </div>
          `}
        </div>
      </div>
    </section>
  `
}

function SummaryCard({ src }: { src: TelemetrySourceSummary }) {
  const meta = sourceMeta(src.source)
  const hasData = src.entry_count > 0
  const statusParts = telemetrySourceStatusParts(src)
  const provenanceRows = telemetrySourceProvenanceRows(src)

  return html`
    <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 min-w-35">
      <div class="flex items-center gap-2 mb-1">
        <span class="font-mono font-bold ${meta.color}">${meta.icon}</span>
        <span class="text-xs font-medium text-[var(--color-fg-primary)]">${meta.label}</span>
      </div>
      ${meta.sublabel ? html`<div class="text-3xs text-[var(--color-fg-disabled)] mb-1">${meta.sublabel}</div>` : null}
      <div class="text-2xl font-bold ${hasData ? 'text-[var(--color-fg-primary)]' : 'text-[var(--color-fg-muted)]'}">
        ${src.entry_count.toLocaleString()}
      </div>
      ${src.keeper_count != null ? html`
        <div class="text-xs text-[var(--color-fg-muted)]">${src.keeper_count} keepers</div>
      ` : null}
      ${src.exists === false ? html`
        <div class="text-xs text-[var(--color-fg-muted)] italic">store not found</div>
      ` : null}
      ${statusParts.length > 0 ? html`
        <div class="mt-2 text-3xs font-mono text-[var(--color-fg-muted)]">${statusParts.join(' · ')}</div>
      ` : null}
      ${provenanceRows.length > 0 ? html`
        <div class="mt-2 grid gap-1 text-3xs text-[var(--color-fg-disabled)]">
          ${provenanceRows.map(row => html`
            <div class="flex min-w-0 gap-1">
              <span class="shrink-0">${row.label}:</span>
              <span class="min-w-0 break-all font-mono">${row.value}</span>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}

function EntryRow({ entry, routeFocused = false }: { entry: TelemetryEntry; routeFocused?: boolean }) {
  const expanded = useSignal(false)
  const meta = sourceMeta(entry.source)
  const ts = entryTimestamp(entry)
  const success = entry.success as boolean | undefined
  const scopeBadges = telemetryScopeBadges(entry)
  const rawJson = useMemo(() => JSON.stringify(entry, null, 2), [entry])
  const focusedClasses = routeFocused
    ? 'border-l-2 border-l-[var(--color-brass-1)] bg-[var(--color-brass-soft)]'
    : ''

  return html`
    <div
      class=${`v2-monitoring-row border-b border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] transition-colors ${focusedClasses}`}
      data-route-focused-telemetry=${routeFocused ? 'true' : undefined}
      style="content-visibility:auto;contain-intrinsic-size:36px"
    >
      <div class="flex items-center gap-1">
        <button
          type="button"
          class=${`min-w-0 flex-1 flex items-center gap-2 px-3 py-1.5 text-xs cursor-pointer select-none text-left ${ringFocusClasses()}`}
          onClick=${() => { expanded.value = !expanded.value }}
          aria-expanded=${expanded.value}
        >
          <span class="font-mono font-bold ${meta.color} w-4 text-center flex-shrink-0">${meta.icon}</span>
          <span class="w-56 flex-shrink-0">
            ${ts === 0
              ? html`<span class="font-mono text-[var(--color-fg-muted)]">-</span>`
              : html`<${TimeAgo} timestamp=${ts} mode="both" class="font-mono text-[var(--color-fg-muted)]"/>`}
          </span>
          ${success != null ? html`
            <span class="flex-shrink-0 w-4 ${success ? 'text-[var(--color-status-ok)]' : 'text-[var(--bad-light)]'}">
              ${success ? 'O' : 'X'}
            </span>
          ` : html`<span class="w-4"></span>`}
          <span class="font-mono text-[var(--color-fg-primary)] truncate flex-1" title=${entryPreview(entry)}>
            ${entryPreview(entry)}
          </span>
          ${scopeBadges.length > 0 ? html`
            <span class="hidden xl:flex items-center gap-1 flex-shrink-0">
              ${scopeBadges.map(badge => html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-disabled)] font-mono">${badge}</span>`)}
            </span>
          ` : null}
          <span class="flex-shrink-0 w-4 text-[var(--color-fg-muted)]">${expanded.value ? '-' : '+'}</span>
        </button>
        <span class="mr-2 inline-flex flex-shrink-0">
          <${CopyIdButton}
            value=${rawJson}
            label="텔레메트리 항목 JSON"
            ariaLabel="텔레메트리 항목 JSON 복사"
            size=${13}
          />
        </span>
      </div>
      ${expanded.value ? html`
        <div class="px-3 pb-3 flex flex-col gap-2">
          ${scopeBadges.length > 0 ? html`
            <div class="flex flex-wrap gap-1.5">
              ${scopeBadges.map(badge => html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs text-[var(--color-fg-disabled)] font-mono">${badge}</span>`)}
            </div>
          ` : null}
          <div class="rounded-[var(--r-1)] bg-[var(--color-bg-surface)] p-2">
            <div class="mb-1.5 flex items-center justify-between gap-2">
              <span class="text-3xs font-medium text-[var(--color-fg-disabled)]">원본 JSON</span>
              <${CopyIdButton}
                value=${rawJson}
                label="펼친 텔레메트리 항목 JSON"
                ariaLabel="펼친 텔레메트리 항목 JSON 복사"
                size=${13}
              />
            </div>
            <pre class="m-0 text-3xs font-mono text-[var(--color-fg-muted)] overflow-x-auto max-h-75 overflow-y-auto whitespace-pre-wrap break-all">
${rawJson}</pre>
          </div>
        </div>
      ` : null}
    </div>
  `
}

function GroupRow({ item, routeFocused = false }: { item: Extract<TelemetryDisplayItem, { kind: 'group' }>; routeFocused?: boolean }) {
  const expanded = useSignal(false)
  const meta = CONDENSED_CATEGORY_META[item.category]
  const latestPreview = entryPreview(item.entries[0] as TelemetryEntry)
  const sourceIcons = uniqueStrings(item.sourceKeys.map(source => sourceMeta(source).icon))
  const contentId = `telemetry-group-${item.key.replace(/[^a-zA-Z0-9_-]/g, '-')}`
  const rawJson = useMemo(() => JSON.stringify(item.entries, null, 2), [item.entries])
  const focusedClasses = routeFocused
    ? 'border-l-2 border-l-[var(--color-brass-1)] bg-[var(--color-brass-soft)]'
    : 'bg-[var(--color-bg-panel-alt)]'

  return html`
    <div
      class=${`v2-monitoring-row border-b border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] transition-colors ${focusedClasses}`}
      data-route-focused-telemetry=${routeFocused ? 'true' : undefined}
      style="content-visibility:auto;contain-intrinsic-size:36px"
    >
      <div class="flex items-center gap-1">
        <button
          type="button"
          class=${`min-w-0 flex-1 flex items-center gap-2 px-3 py-1.5 text-xs cursor-pointer select-none text-left ${ringFocusClasses()}`}
          aria-expanded=${expanded.value}
          aria-controls=${contentId}
          onClick=${() => { expanded.value = !expanded.value }}
        >
          <span class="font-mono font-bold ${meta.color} w-4 text-center flex-shrink-0">${meta.icon}</span>
          <span class="w-56 flex-shrink-0" title=${`${formatTs(item.oldestTs)} → ${formatTs(item.latestTs)}`}>
            ${item.latestTs === 0
              ? html`<span class="font-mono text-[var(--color-fg-muted)]">-</span>`
              : html`<${TimeAgo} timestamp=${item.latestTs} mode="both" class="font-mono text-[var(--color-fg-muted)]"/>`}
          </span>
          <span class="flex-shrink-0 w-4 text-[var(--color-fg-disabled)]">~</span>
          <span class="font-mono text-[var(--color-fg-primary)] truncate flex-1" title=${`${meta.label} · ${item.label} · ${item.count} events`}>
            ${meta.label} · ${item.label} · ${item.count} events
          </span>
          ${sourceIcons.length > 0 ? html`
            <span class="hidden lg:flex items-center gap-1 flex-shrink-0 text-3xs text-[var(--color-fg-disabled)] font-mono">
              ${sourceIcons.join('/')}
            </span>
          ` : null}
          ${item.scopeBadges.length > 0 ? html`
            <span class="hidden xl:flex items-center gap-1 flex-shrink-0">
              ${item.scopeBadges.map(badge => html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-disabled)] font-mono">${badge}</span>`)}
            </span>
          ` : null}
          <span class="flex-shrink-0 w-4 text-[var(--color-fg-muted)]">${expanded.value ? '-' : '+'}</span>
        </button>
        <span class="mr-2 inline-flex flex-shrink-0">
          <${CopyIdButton}
            value=${rawJson}
            label="텔레메트리 그룹 JSON"
            ariaLabel="텔레메트리 그룹 JSON 복사"
            size=${13}
          />
        </span>
      </div>
      <div id=${contentId} class=${expanded.value ? 'px-3 pb-3 flex flex-col gap-2' : 'hidden'}>
        ${expanded.value ? html`
          <div class="rounded-[var(--r-1)] bg-[var(--color-bg-surface)] px-2 py-1.5 text-2xs text-[var(--color-fg-disabled)]">
            Latest: <span class="font-mono text-[var(--color-fg-primary)]">${latestPreview}</span>
          </div>
          ${item.entries.map((entry, index) => {
            const entryMeta = sourceMeta(entry.source)
            const ts = entryTimestamp(entry)
            return html`
              <div class="flex items-center gap-2 rounded-[var(--r-1)] bg-[var(--black-20)] px-2 py-1.5 text-3xs" key=${`${item.key}:${index}`}>
                <span class="font-mono font-bold ${entryMeta.color} w-4 text-center flex-shrink-0">${entryMeta.icon}</span>
                <span class="w-48 flex-shrink-0">
                  ${ts === 0
                    ? html`<span class="font-mono text-[var(--color-fg-disabled)]">-</span>`
                    : html`<${TimeAgo} timestamp=${ts} mode="both" class="font-mono text-[var(--color-fg-disabled)]"/>`}
                </span>
                <span class="font-mono text-[var(--color-fg-primary)] truncate flex-1" title=${entryPreview(entry)}>${entryPreview(entry)}</span>
              </div>
            `
          })}
          <div class="rounded-[var(--r-1)] bg-[var(--black-20)] px-2 py-1.5">
            <div class="flex items-start justify-between gap-2">
              <details class="min-w-0 flex-1">
                <summary class="cursor-pointer text-3xs text-[var(--color-fg-disabled)]">원본 JSON</summary>
                <pre class="mt-2 text-3xs font-mono text-[var(--color-fg-muted)] overflow-x-auto max-h-70 overflow-y-auto whitespace-pre-wrap break-all">
${rawJson}</pre>
              </details>
              <${CopyIdButton}
                value=${rawJson}
                label="펼친 텔레메트리 그룹 JSON"
                ariaLabel="펼친 텔레메트리 그룹 JSON 복사"
                size=${13}
              />
            </div>
          </div>
        ` : null}
      </div>
    </div>
  `
}

function TelemetryRouteFocusPanel({
  focus,
  matchCount,
}: {
  focus: TelemetryRouteFocus | null
  matchCount: number
}) {
  if (!focus) return null
  const badges = telemetryRouteFocusBadges(focus)
  return html`
    <section
      class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] px-3 py-2"
      data-testid="telemetry-route-focus"
      aria-label="Telemetry route focus"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="font-mono text-3xs font-semibold uppercase tracking-[var(--track-section)] text-[var(--color-accent-fg)]">
            ROUTE FOCUS
          </div>
          <div class="mt-1 flex min-w-0 flex-wrap items-center gap-2 text-xs text-[var(--color-fg-secondary)]">
            ${badges.map(badge => html`
              <span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-accent-fg)]">
                ${badge.label} ${badge.value}
              </span>
            `)}
            <span class="font-mono text-3xs text-[var(--color-fg-muted)]">
              ${matchCount.toLocaleString()} focused item${matchCount === 1 ? '' : 's'}
            </span>
          </div>
        </div>
        <button
          type="button"
          class="v2-monitoring-action rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
          onClick=${clearTelemetryRouteFocus}
        >
          CLEAR
        </button>
      </div>
    </section>
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
    telemetry: null,
    summary: [],
    totalEntries: 0,
    store: EMPTY_STORE,
    cacheStats: null,
    cacheStatsError: null,
    loading: true,
    error: null,
  })
  const sourceFilter = useSignal<TelemetrySource | ''>(telemetrySourceFromRouteParam(params.source))
  const keeperFilter = useSignal('')
  const sessionFilter = useSignal(params.session_id ?? '')
  const operationFilter = useSignal(params.operation_id ?? '')
  const workerRunFilter = useSignal(params.worker_run_id ?? '')
  const limit = useSignal(telemetryLimitFromRouteParam(params.n ?? params.limit))
  const entrySearch = useSignal(params.q ?? '')

  useEffect(() => {
    sourceFilter.value = telemetrySourceFromRouteParam(route.value.params.source)
    sessionFilter.value = route.value.params.session_id ?? ''
    operationFilter.value = route.value.params.operation_id ?? ''
    workerRunFilter.value = route.value.params.worker_run_id ?? ''
    limit.value = telemetryLimitFromRouteParam(route.value.params.n ?? route.value.params.limit)
    entrySearch.value = route.value.params.q ?? ''
  }, [
    route.value.params.source,
    route.value.params.session_id,
    route.value.params.operation_id,
    route.value.params.worker_run_id,
    route.value.params.n,
    route.value.params.limit,
    route.value.params.q,
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
      const cacheStatsPromise = fetchDashboardCacheStats({ signal: controller.signal })
        .then(cacheStats => ({ cacheStats, cacheStatsError: null as string | null }))
        .catch(error => {
          if (isAbortError(error)) throw error
          return {
            cacheStats: null,
            cacheStatsError: errorToString(error),
          }
        })
      const [telemetry, , store, cacheStatsResult] = await Promise.all([
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
        cacheStatsPromise,
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
        telemetry,
        summary: summary.sources,
        totalEntries: summary.total_entries,
        store,
        cacheStats: cacheStatsResult.cacheStats,
        cacheStatsError: cacheStatsResult.cacheStatsError,
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
  const { telemetry, cacheStats, cacheStatsError } = state.value
  const entrySearchQuery = entrySearch.value
  const allDisplayItems = useMemo(() => buildTelemetryDisplayItems(entries), [entries])
  const displayItems = useMemo(
    () => filterTelemetryDisplayItems(allDisplayItems, entrySearchQuery),
    [allDisplayItems, entrySearchQuery],
  )
  const routeFocus = useMemo(
    () => telemetryRouteFocusFromParams(route.value.params as Record<string, string | undefined>),
    [
      route.value.params.session_id,
      route.value.params.operation_id,
      route.value.params.worker_run_id,
      route.value.params.q,
    ],
  )
  const routeFocusedItemKeys = useMemo(() => {
    if (!routeFocus) return new Set<string>()
    return new Set(displayItems
      .filter(item => telemetryDisplayItemMatchesRouteFocus(item, routeFocus))
      .map(item => item.key))
  }, [displayItems, routeFocus])
  const isFilteringEntries = entrySearchQuery.trim() !== ''
  const condensed = useMemo(() => condensedStats(displayItems), [displayItems])

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <div class="v2-monitoring-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        <div class="text-xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">런타임 진단</div>
        <div class="mt-2 flex flex-wrap gap-2">
          <span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs text-[var(--color-fg-disabled)]">MASC: keeper/tool/agent store</span>
          ${sessionFilter.value ? html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs font-mono text-[var(--color-fg-disabled)]">session ${sessionFilter.value}</span>` : null}
          ${operationFilter.value ? html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs font-mono text-[var(--color-fg-disabled)]">operation ${operationFilter.value}</span>` : null}
          ${workerRunFilter.value ? html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs font-mono text-[var(--color-fg-disabled)]">worker_run ${workerRunFilter.value}</span>` : null}
          ${sourceFilter.value ? html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs font-mono text-[var(--color-fg-disabled)]">source ${telemetrySourceMeta(sourceFilter.value).label}</span>` : null}
          ${limit.value !== 100 ? html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs font-mono text-[var(--color-fg-disabled)]">limit ${limit.value}</span>` : null}
          ${route.value.params.q ? html`<span class="rounded-[var(--r-1)] border border-[var(--color-accent-muted)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs font-mono text-[var(--color-accent-fg)]">focus ${route.value.params.q}</span>` : null}
        </div>
      </div>

      <${OasHealthChip} />

      <${TelemetryCachePanel}
        telemetry=${telemetry}
        summary=${summary}
        cacheStats=${cacheStats}
        cacheStatsError=${cacheStatsError}
      />

      <${TelemetryRouteFocusPanel} focus=${routeFocus} matchCount=${routeFocusedItemKeys.size} />

      <div class="flex flex-wrap gap-3">
        ${summary.map(src => html`<${SummaryCard} src=${src} />`)}
        <${StatTile}
          label="전체"
          value=${totalEntries.toLocaleString()}
        />
      </div>

      <div class="flex flex-wrap gap-3">
        <${StatTile}
          label="키퍼 현황 (실시간)"
          value=${String(store.keepers)}
          status=${store.continuityAlerts > 0 ? 'warn' : store.keepers > 0 ? 'ok' : undefined}
          delta=${{ direction: store.continuityAlerts > 0 ? 'down' as const : 'up' as const, text: [
            `${store.activeOperations} 활성 작업`,
            store.blockedOperations > 0 ? `${store.blockedOperations} 차단 작업` : null,
            `${store.continuityAlerts} continuity 알림`,
            store.version ? `v${store.version}` : null,
            store.uptime != null ? `uptime ${Math.floor(store.uptime / 60)}m` : null,
          ].filter(Boolean).join(' · ') }}
        />
        <${StatTile}
          label="도구 등록 현황 (실시간)"
          value=${String(store.toolsRegistered)}
          status=${store.toolsRegistered > 0 ? 'ok' : 'warn'}
          delta=${{ direction: store.toolsRegistered > 0 ? 'up' as const : 'flat' as const, text: `${store.toolsPublic} public · ${store.toolsTotalCalls.toLocaleString()} 총 호출 · ${store.toolsNeverCalled} 미사용` }}
        />
        <${StatTile}
          label="에이전트 현황 (실시간)"
          value=${String(store.agents)}
          status=${store.agents > 0 ? 'ok' : undefined}
          delta=${{ direction: store.agents > 0 ? 'up' as const : 'flat' as const, text: `${store.tasks} 태스크 · ${store.activeOperations} 활성 작전` }}
        />
      </div>

      <div class="flex items-center gap-3 flex-wrap">
        <select
          aria-label="텔레메트리 소스 필터"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)]"
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
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)] w-32"
          value=${keeperFilter.value}
          onInput=${(e: Event) => { keeperFilter.value = (e.target as HTMLInputElement).value }}
        />
        <input
          type="text"
          placeholder="session_id"
          aria-label="session_id 필터"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)] w-40 font-mono"
          value=${sessionFilter.value}
          onInput=${(e: Event) => { sessionFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="operation_id"
          aria-label="operation_id 필터"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)] w-40 font-mono"
          value=${operationFilter.value}
          onInput=${(e: Event) => { operationFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="worker_run_id"
          aria-label="worker_run_id 필터"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)] w-40 font-mono"
          value=${workerRunFilter.value}
          onInput=${(e: Event) => { workerRunFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="search"
          placeholder="엔트리 검색..."
          aria-label="엔트리 텍스트 검색"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)] w-48"
          value=${entrySearch.value}
          onInput=${(e: Event) => { entrySearch.value = (e.target as HTMLInputElement).value }}
        />
        <select
          aria-label="표시 개수 제한"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-xs text-[var(--color-fg-primary)]"
          value=${String(limit.value)}
          onChange=${(e: Event) => { limit.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="50">50</option>
          <option value="100">100</option>
          <option value="200">200</option>
          <option value="500">500</option>
        </select>
        <${Btn} onClick=${() => void load()}>
          Refresh
        <//>
        <span class="text-xs text-[var(--color-fg-muted)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        ${loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
      </div>

      ${error ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-xs text-[var(--bad-light)]" role="alert">
          ${error}
        </div>
      ` : null}

      <div class="v2-monitoring-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] overflow-hidden">
        <div class="px-3 py-2 border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-xs text-[var(--color-fg-muted)]">
          MASC telemetry store entries ${entries.length.toLocaleString()}건
          ${isFilteringEntries
            ? ` · 검색 매치 ${displayItems.length.toLocaleString()}건`
            : ''}
          ${condensed.groups > 0
            ? ` · 접힌 그룹 ${condensed.groups.toLocaleString()}개 · 원본 ${condensed.groupedEntries.toLocaleString()}건`
            : ''}
        </div>
        ${condensed.groups > 0 ? html`
          <div class="px-3 py-2 border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] flex flex-wrap gap-2 text-2xs">
            ${Array.from(condensed.byCategory.entries()).map(([category, count]) => {
              const meta = CONDENSED_CATEGORY_META[category]
              return html`
                <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-[var(--color-fg-disabled)]">
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
              ? html`<${GroupRow} key=${item.key} item=${item} routeFocused=${routeFocusedItemKeys.has(item.key)} />`
              : html`<${EntryRow} key=${item.key} entry=${item.entry} routeFocused=${routeFocusedItemKeys.has(item.key)} />`)
            : isFilteringEntries && allDisplayItems.length > 0
              ? html`<div class="px-4 py-6 text-sm text-[var(--color-fg-muted)]">필터 결과 없음 (${allDisplayItems.length} items)</div>`
              : html`<div class="px-4 py-6 text-sm text-[var(--color-fg-muted)]">선택한 scope에 해당하는 MASC telemetry entry가 없습니다.</div>`}
        </div>
      </div>
    </div>
  `
}

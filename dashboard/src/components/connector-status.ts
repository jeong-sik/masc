// Connector Status — Channel Gate per-channel diagnostics panel.
// Keeper-first layout: each directory keeper is a primary section; bindings nest under.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import { post } from '../api/core'
import {
  fetchGateConnectors,
  fetchGateKeepers,
  fetchGateStatus,
  type BindingInfo,
  type ChannelInfo,
  type ConnectorNames,
  type GateConnectorInfo,
  type GateConnectorsData,
  type GateEventInfo,
  type GateKeeperInfo,
  type GateStatusData,
} from '../api/gate'
import { formatElapsedCompact, formatTimeAgoEn } from '../lib/format-time'
import { ErrorState } from './common/feedback-state'
import { ConnectorOverviewSkeleton } from './connector-overview-skeleton'
import { lastEvent } from '../sse'
import { StatCard } from './common/stat-card'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { showToast } from './common/toast'
import { CopyableCode } from './common/copyable-code'
import { SetupGuideCard } from './setup-guide-card'
import { ConnectorOnboardingGrid } from './connector-onboarding'
import { SidecarLogToggle, SidecarLogViewer } from './sidecar-log-viewer'
import { ConnectorConfigToggle, ConnectorConfigForm, openConnectorConfig } from './connector-config-form'
import { ConnectorReadinessRail, deriveRail, getRailInflight, withRailInflight } from './connector-readiness-rail'
import { StartupCheckBanner, markStartAttempt, clearStartAttempt } from './sidecar-startup-watch'
import { QuickBindForm } from './connector-quick-bind'
import { ConnectorOverviewStrip } from './connector-overview-strip'
import { ConnectorKeeperMatrix, deriveMatrix } from './connector-keeper-matrix'
import { ConnectorPathsStrip } from './connector-paths-strip'
import { createManagedAsyncResource } from '../lib/async-state'
import { route } from '../router'

// Sub-section -> connector_id filter. `connector-status` (default) shows
// all connectors; the per-connector sub-sections show just that one. Source
// of truth: dashboard/src/config/navigation.ts DASHBOARD_SECTION_ITEMS.connectors.
const SECTION_TO_CONNECTOR_ID: Record<string, string | null> = {
  'connector-status': null,
  'connector-discord': 'discord',
  'connector-imessage': 'imessage',
  'connector-slack': 'slack',
  'connector-telegram': 'telegram',
}

function activeConnectorFilter(): string | null {
  const section = route.value.params.section
  if (!section) return null
  return SECTION_TO_CONNECTOR_ID[section] ?? null
}

// Per-connector lifecycle hints. All four sidecars now ship a run.sh wrapper
// (discord/imessage/slack/telegram) — see sidecars/<id>-bot/run.sh.
// Source of truth: docs/CONNECTOR-CONFIG-SCHEMA.md.
interface SidecarCommands {
  start: string
  tail: string
  status: string
  stop: string
}

// Known connectors with first-class onboarding/lifecycle support. Source of
// truth: the four sidecars under /sidecars/ and config/navigation.ts.
export const KNOWN_CONNECTOR_IDS = ['discord', 'imessage', 'slack', 'telegram'] as const
export type KnownConnectorId = (typeof KNOWN_CONNECTOR_IDS)[number]

export const CONNECTOR_DISPLAY_NAMES: Record<KnownConnectorId, string> = {
  discord: 'Discord',
  imessage: 'iMessage',
  slack: 'Slack',
  telegram: 'Telegram',
}

const SIDECAR_DIRS: Record<string, string> = {
  discord: 'sidecars/discord-bot',
  imessage: 'sidecars/imessage-bot',
  slack: 'sidecars/slack-bot',
  telegram: 'sidecars/telegram-bot',
}

export function sidecarCommands(connectorId: string): SidecarCommands {
  const dir = SIDECAR_DIRS[connectorId] ?? `sidecars/${connectorId}-bot`
  return {
    start: `cd ${dir} && ./run.sh`,
    tail: `cd ${dir} && ./run.sh tail`,
    status: `cd ${dir} && ./run.sh status`,
    stop: `cd ${dir} && ./run.sh stop`,
  }
}

// Brand accent RGB triplets per connector. Used as a subtle 135deg gradient
// behind the panel header so an operator scanning many connectors can tell
// them apart without reading the title. Values picked from each platform's
// official brand palette, biased toward dark-theme legibility.
const CONNECTOR_ACCENT_RGB: Record<string, string> = {
  discord: '88,101,242',   // blurple
  imessage: '48,209,88',   // iOS Messages bubble green
  slack: '236,178,46',     // brand yellow (most distinctive vs telegram cyan)
  telegram: '34,158,217',  // brand cyan
}

export function connectorAccentStyle(connectorId: string): string {
  const rgb = CONNECTOR_ACCENT_RGB[connectorId] ?? '120,130,150'
  return `background:linear-gradient(135deg,rgba(${rgb},0.16),rgba(${rgb},0.04))`
}

interface ConnectorUiState {
  actionLoading: boolean
  channelDraft: string
  expandedKeeperFor: string | null
  headerExpanded: boolean
  keeperGroupQuery: string
}

function emptyConnectorUiState(): ConnectorUiState {
  return {
    actionLoading: false,
    channelDraft: '',
    expandedKeeperFor: null,
    headerExpanded: false,
    keeperGroupQuery: '',
  }
}

const connectorUiState = signal<Record<string, ConnectorUiState>>({})
const selectedConnectorId = signal<KnownConnectorId | null>(null)

function getConnectorUiState(connectorId: string): ConnectorUiState {
  return connectorUiState.value[connectorId] ?? emptyConnectorUiState()
}

function patchConnectorUiState(connectorId: string, patch: Partial<ConnectorUiState>) {
  if (!connectorId) return
  connectorUiState.value = {
    ...connectorUiState.value,
    [connectorId]: {
      ...getConnectorUiState(connectorId),
      ...patch,
    },
  }
}

/**
 * Pure filter for keeper groups rendered in the "Keeper-first" panel.
 *
 * Case-insensitive substring match on `group.name`, the keeper's
 * resolved model label (active_model / model / primary_model), and
 * the keeper's resolved runtime label (agent_name when distinct from
 * name). Operators on a crowded connector can locate a keeper by
 * partial name, by the model it is running, or by its runtime agent.
 *
 * Empty/whitespace query returns the input reference unchanged (no
 * new array allocation, preserves referential equality).
 *
 * Input is never mutated. `unknown` keeper groups are surfaced
 * separately below this panel, so the filter only applies to the
 * `knownGroups` array — matching what the operator can see.
 */
export function filterKeeperGroups(
  groups: readonly KeeperGroup[],
  query: string,
): readonly KeeperGroup[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return groups
  return groups.filter(group => {
    if (group.name.toLowerCase().includes(needle)) return true
    const model = modelLabelForKeeper(group.keeper).toLowerCase()
    if (model !== '' && model.includes(needle)) return true
    const runtime = runtimeLabelForKeeper(group.keeper).toLowerCase()
    if (runtime !== '' && runtime.includes(needle)) return true
    return false
  })
}

type ConnectorStatusSnapshot = {
  gate: GateStatusData | null
  connectors: GateConnectorsData | null
  keepers: GateKeeperInfo[]
  gateError: string | null
  connectorError: string | null
  keeperError: string | null
}

const EMPTY_SNAPSHOT: ConnectorStatusSnapshot = {
  gate: null,
  connectors: null,
  keepers: [],
  gateError: null,
  connectorError: null,
  keeperError: null,
}

const connectorStatusResource = createManagedAsyncResource<ConnectorStatusSnapshot>(EMPTY_SNAPSHOT)

async function refresh() {
  await connectorStatusResource.load(async (signal, previous) => {
    const next: ConnectorStatusSnapshot = {
      gate: previous?.gate ?? null,
      connectors: previous?.connectors ?? null,
      keepers: previous?.keepers ?? [],
      gateError: null,
      connectorError: null,
      keeperError: null,
    }

    const [gateResult, connResult, keeperResult] = await Promise.allSettled([
      fetchGateStatus(signal),
      fetchGateConnectors(signal),
      fetchGateKeepers(signal),
    ])

    if (gateResult.status === 'fulfilled') {
      next.gate = gateResult.value
    } else {
      next.gateError = gateResult.reason instanceof Error ? gateResult.reason.message : 'fetch failed'
    }

    if (connResult.status === 'fulfilled') {
      next.connectors = connResult.value
    } else {
      next.connectorError = connResult.reason instanceof Error ? connResult.reason.message : 'fetch failed'
    }

    if (keeperResult.status === 'fulfilled') {
      next.keepers = keeperResult.value.keepers ?? []
    } else {
      next.keepers = []
      next.keeperError = keeperResult.reason instanceof Error ? keeperResult.reason.message : 'fetch failed'
    }

    return next
  })
}

const CHANNEL_ICONS: Record<string, string> = {
  discord: '\u{1F3AE}',
  imessage: '\u{1F4F1}',
  telegram: '\u{2708}',
  slack: '\u{1F4AC}',
  signal: '\u{1F512}',
  webchat: '\u{1F310}',
  api: '\u{26A1}',
  internal: '\u{2699}',
}

export function channelIcon(ch: string): string {
  return CHANNEL_ICONS[ch] ?? '\u{1F517}'
}

const formatUptime = formatElapsedCompact

// ── Header stat strip helpers (Grafana Stat-panel style big-number + label) ──

type HeaderStatTone = 'ok' | 'partial' | 'bad' | 'default'

/** Pure: threshold tone for "N of M connected" header stat. Grafana
    Stat-panel convention — emerald when all up, amber when partial,
    rose when zero. Exposed so downstream tests can pin the thresholds
    without mounting the panel. */
export function headerConnectedTone(connected: number, total: number): HeaderStatTone {
  if (total <= 0) return 'default'
  if (connected >= total) return 'ok'
  if (connected <= 0) return 'bad'
  return 'partial'
}

/** Pure: threshold tone for a success-rate % stat. Grafana default
    thresholds — ≥95 green, 70-95 amber, <70 red. */
export function headerSuccessTone(successPct: number | null | undefined): HeaderStatTone {
  if (successPct === null || successPct === undefined || Number.isNaN(successPct)) return 'default'
  if (successPct >= 95) return 'ok'
  if (successPct >= 70) return 'partial'
  return 'bad'
}

/** Pure: map header tone to a Tailwind text-color utility. */
export function headerStatToneClass(tone: HeaderStatTone): string {
  switch (tone) {
    case 'ok':      return 'text-[var(--ok)]'
    case 'partial': return 'text-[var(--warn)]'
    case 'bad':     return 'text-[var(--bad-light)]'
    case 'default':
    default:        return 'text-[var(--text-body)]'
  }
}

interface HeaderMiniStatProps {
  label: string
  value: string
  tone?: HeaderStatTone
  testId?: string
}

/** Inline mini Grafana-style stat tile — big tabular value on top,
    tiny uppercase label below, threshold-colored by `tone`. Used by
    the connector panel header; kept local because the surrounding
    layout (right-aligned corner trio) doesn't generalize to a shared
    primitive yet. Promote to common/ once a second caller emerges. */
export function HeaderMiniStat({
  label,
  value,
  tone = 'default',
  testId,
}: HeaderMiniStatProps) {
  const valueTone = headerStatToneClass(tone)
  return html`
    <div
      class="flex min-w-15 flex-col items-end justify-center rounded border border-[var(--white-8)] bg-[var(--white-2)] px-2 py-1 text-right"
      data-header-mini-stat=${label}
      data-header-mini-stat-tone=${tone}
      data-testid=${testId}
    >
      <span class=${`text-sm font-semibold tabular-nums leading-tight ${valueTone}`}>${value}</span>
      <span class="mt-0.5 text-3xs uppercase tracking-5 text-[var(--text-dim)]">${label}</span>
    </div>
  `
}
const timeAgo = formatTimeAgoEn

function healthTone(health: string): { dot: string; badge: string; label: string } {
  switch (health) {
    case 'healthy':
      return {
        dot: 'var(--green)',
        badge: 'border border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok)]',
        label: 'healthy',
      }
    case 'degraded':
      return {
        dot: 'var(--yellow)',
        badge: 'border border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]',
        label: 'degraded',
      }
    case 'failing':
      return {
        dot: 'var(--red)',
        badge: 'border border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]',
        label: 'failing',
      }
    default:
      return {
        dot: 'var(--text-dim)',
        badge: 'border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-dim)]',
        label: health || 'idle',
      }
  }
}

function shortText(value: string, limit = 96): string {
  const trimmed = value.trim()
  if (!trimmed) return ''
  if (trimmed.length <= limit) return trimmed
  return `${trimmed.slice(0, limit - 1)}…`
}

function truncateMiddle(value: string, limit = 18): string {
  const trimmed = value.trim()
  if (!trimmed) return '-'
  if (trimmed.length <= limit) return trimmed
  if (limit <= 5) return `${trimmed.slice(0, Math.max(1, limit - 1))}…`
  const budget = limit - 1
  const tail = Math.max(4, Math.floor(budget / 3))
  const head = Math.max(2, budget - tail)
  return `${trimmed.slice(0, head)}…${trimmed.slice(-tail)}`
}

function humanizeChannel(names: ConnectorNames | undefined, channelId: string): string {
  if (!names) return ''
  const channelName = names.channel_names[channelId]
  const guildId = names.channel_to_guild[channelId]
  const guildName = guildId ? names.guild_names[guildId] : undefined
  if (!channelName && !guildName) return ''
  if (channelName && guildName) return `${channelName} in "${guildName}"`
  return channelName || `in "${guildName}"`
}

type LivenessState = 'ok' | 'warn' | 'down' | 'unknown'

interface LivenessDot {
  label: string
  state: LivenessState
  detail: string
  hint: string
}

function dotClass(state: LivenessState): string {
  switch (state) {
    case 'ok':
      return 'bg-[var(--ok-10)]'
    case 'warn':
      return 'bg-[var(--warn-10)]'
    case 'down':
      return 'bg-[var(--bad-10)]'
    default:
      return 'bg-[var(--text-dim)]'
  }
}

function dotClassForLabel(label: string): string {
  switch (label) {
    case 'connected':
      return 'bg-[var(--ok-10)]'
    case 'stale':
      return 'bg-[var(--warn-10)]'
    case 'disconnected':
      return 'bg-[var(--bad-10)]'
    default:
      return 'bg-[var(--text-dim)]'
  }
}

function uniqueStrings(values: string[]): string[] {
  const seen = new Set<string>()
  const ordered: string[] = []
  values.forEach(value => {
    const trimmed = value.trim()
    if (!trimmed || seen.has(trimmed)) return
    seen.add(trimmed)
    ordered.push(trimmed)
  })
  return ordered
}

function modelLabelForKeeper(keeper: GateKeeperInfo | null | undefined): string {
  return keeper?.active_model?.trim()
    || keeper?.model?.trim()
    || keeper?.primary_model?.trim()
    || ''
}

function runtimeLabelForKeeper(keeper: GateKeeperInfo | null | undefined): string {
  const runtime = keeper?.agent_name?.trim()
  if (!runtime || runtime === keeper?.name) return ''
  return runtime
}

export function connectorStateLabel(connector: GateConnectorInfo | null): string {
  const advertised = connector?.status?.trim().toLowerCase()
  if (advertised === 'offline' || advertised === 'stale' || advertised === 'connected' || advertised === 'disconnected') {
    return advertised
  }
  if (!connector?.available) return 'offline'
  if (connector.stale) return 'stale'
  if (connector.connected) return 'connected'
  return 'disconnected'
}

/** Pure: Portainer-style left border tone for a connector card.
    A 4px colored left border lets operators scan a vertical stack of
    cards and spot problem connectors by color alone — no reading the
    status pill required. Mapping matches Portainer's container state
    palette: emerald for connected, amber for stale (intermittent),
    rose for disconnected (broken), muted for offline (not running). */
export function connectorCardBorderClass(label: string): string {
  switch (label) {
    case 'connected':
      return 'border-l-4 border-l-emerald-500'
    case 'stale':
      return 'border-l-4 border-l-amber-500'
    case 'disconnected':
      return 'border-l-4 border-l-rose-500'
    case 'offline':
    default:
      return 'border-l-4 border-l-[var(--white-10)]'
  }
}

function connectorStateTone(connector: GateConnectorInfo | null): string {
  const label = connectorStateLabel(connector)
  if (label === 'connected') {
    return 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok)]'
  }
  if (label === 'disconnected') {
    return 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]'
  }
  return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]'
}

function findKnownConnector(connectors: GateConnectorInfo[], connectorId: KnownConnectorId): GateConnectorInfo | null {
  return connectors.find(connector => connector.connector_id === connectorId) ?? null
}

function connectorFocusScore(
  connector: GateConnectorInfo | null,
  keeperCount: number,
): number {
  if (connector === null) return 30
  const state = connectorStateLabel(connector)
  if (state === 'stale' || state === 'disconnected') return 100
  if (connector.available !== true) return 40
  if (connector.gate_healthy === false) return 90
  const bindingCount = connector.configured_bindings?.length ?? 0
  if (keeperCount > 0 && bindingCount === 0) return 80
  if (bindingCount === 0) return 70
  if (state === 'connected') return 60
  return 20
}

function resolveConnectorFocusId(
  connectors: GateConnectorInfo[],
  keeperCount: number,
  preferredId: KnownConnectorId | null,
): KnownConnectorId {
  if (preferredId !== null) return preferredId
  let bestId: KnownConnectorId = KNOWN_CONNECTOR_IDS[0]
  let bestScore = Number.NEGATIVE_INFINITY
  for (const connectorId of KNOWN_CONNECTOR_IDS) {
    const score = connectorFocusScore(findKnownConnector(connectors, connectorId), keeperCount)
    if (score > bestScore) {
      bestScore = score
      bestId = connectorId
    }
  }
  return bestId
}

function placeholderConnector(connectorId: KnownConnectorId): GateConnectorInfo {
  return {
    connector_id: connectorId,
    display_name: CONNECTOR_DISPLAY_NAMES[connectorId],
    channel: connectorId,
    capabilities: ['bindings'],
    status: 'offline',
    available: false,
    connected: false,
    stale: false,
    stale_after_sec: 0,
    error: '',
    status_path: '',
    binding_store_path: '',
    audit_path: '',
    updated_at: '',
    reply_mode: '',
    self_chat_guid: '',
    last_ready_at: '',
    bot_user_name: '',
    bot_user_id: '',
    guild_count: 0,
    gate_base_url: '',
    gate_healthy: null,
    gate_health_checked_at: '',
    binding_source: '',
    runtime_bindings_count: 0,
    pid: 0,
    configured_bindings: [],
    recent_audit: [],
    storage_paths: {
      status_path: '',
      binding_store_path: '',
      audit_path: '',
      names_path: '',
    },
    runtime_summary: {
      available: false,
      connected: false,
      stale: false,
      stale_after_sec: 0,
      status: 'offline',
      error: '',
      updated_at: '',
      reply_mode: '',
      self_chat_guid: '',
      last_ready_at: '',
      bot_user_name: '',
      bot_user_id: '',
      guild_count: 0,
      gate_base_url: '',
      gate_healthy: null,
      gate_health_checked_at: '',
      pid: 0,
    },
    binding_summary: {
      binding_source: '',
      runtime_bindings_count: 0,
      configured_bindings_count: 0,
    },
    observed_channel: null,
    names_path: '',
    names: {
      guild_names: {},
      channel_names: {},
      channel_to_guild: {},
      updated_at: '',
    },
  }
}

// Native lifecycle hits the new /api/v1/sidecar/{start,stop} endpoints
// (see lib/server/server_routes_http_routes_sidecar.ml). The endpoints
// shell out to the same ./run.sh wrapper the operator would otherwise
// run by hand, so the dashboard button and the copy-paste command are
// behaviourally identical — only convenience differs.
export async function startSidecar(connectorId: string) {
  patchConnectorUiState(connectorId, { actionLoading: true })
  markStartAttempt(connectorId)
  try {
    await post(`/api/v1/sidecar/start?name=${encodeURIComponent(connectorId)}`, {})
    showToast(`${connectorId} sidecar 시작 요청 — 잠시 후 상태 갱신됩니다.`, 'success')
    await refresh()
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'start failed', 'error')
  } finally {
    patchConnectorUiState(connectorId, { actionLoading: false })
  }
}

export async function stopSidecar(connectorId: string) {
  patchConnectorUiState(connectorId, { actionLoading: true })
  // Stop is the operator's signal that the previous start attempt is no
  // longer relevant — the startup-warning would just be misleading.
  clearStartAttempt(connectorId)
  try {
    await post(`/api/v1/sidecar/stop?name=${encodeURIComponent(connectorId)}`, {})
    showToast(`${connectorId} sidecar에 SIGTERM 전송`, 'success')
    await refresh()
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'stop failed', 'error')
  } finally {
    patchConnectorUiState(connectorId, { actionLoading: false })
  }
}

export async function bindConnector(connectorId: string, keeperName: string, channelId: string) {
  const keeper = keeperName.trim()
  const channel = channelId.trim()
  if (!keeper || !channel) return

  patchConnectorUiState(connectorId, { actionLoading: true })
  try {
    await post(`/api/v1/gate/connector/bind?name=${encodeURIComponent(connectorId)}`, {
      channel_id: channel,
      keeper_name: keeper,
    })
    patchConnectorUiState(connectorId, {
      channelDraft: '',
      expandedKeeperFor: null,
    })
    await refresh()
    showToast(`Bound ${channel} -> ${keeper}`, 'success')
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'bind failed', 'error')
  } finally {
    patchConnectorUiState(connectorId, { actionLoading: false })
  }
}

export async function unbindConnector(connectorId: string, channelId: string) {
  const channel = channelId.trim()
  if (!channel) return

  patchConnectorUiState(connectorId, { actionLoading: true })
  try {
    await post(`/api/v1/gate/connector/unbind?name=${encodeURIComponent(connectorId)}`, {
      channel_id: channel,
    })
    await refresh()
    showToast(`Unbound ${channel}`, 'success')
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'unbind failed', 'error')
  } finally {
    patchConnectorUiState(connectorId, { actionLoading: false })
  }
}

type KeeperGroup = {
  name: string
  keeper: GateKeeperInfo | null
  bindings: Array<{ channel_id: string; keeper_name: string }>
  unknown: boolean
}

function ConnectorLivePanel({
  connector,
  gate,
  keepers,
  connectorError,
  keeperDirectoryError,
  loading,
}: {
  connector: GateConnectorInfo | null
  gate: GateStatusData | null
  keepers: GateKeeperInfo[]
  connectorError: string | null
  keeperDirectoryError: string | null
  loading: boolean
}) {
  const configuredBindings = connector?.configured_bindings ?? []
  const names = connector?.names
  const connectorName = connector?.display_name || 'Connector'
  const connectorId = connector?.connector_id ?? ''
  const ui = getConnectorUiState(connectorId)
  const isActionLoading = ui.actionLoading
  const bindingActionsEnabled = connector != null && connector.capabilities.includes('bindings')
  const directLabel = connectorStateLabel(connector)
  const directTone = connectorStateTone(connector)

  let gateHealthLabel = 'unknown'
  if (connector?.gate_healthy === true) {
    gateHealthLabel = 'healthy'
  } else if (connector?.gate_healthy === false) {
    gateHealthLabel = 'unhealthy'
  }

  const sidecarLogPath = connector?.names_path
    ? connector.names_path.replace(
        /\/\.masc\/connectors\/[^/]+\/names\.json$/,
        `/.masc/logs/${connectorId}-sidecar-YYYYMMDD.log`,
      )
    : ''

  const observedRooms = uniqueStrings([
    ...(gate?.bindings ?? [])
      .filter(binding => binding.channel === (connector?.channel ?? ''))
      .map(binding => binding.room_id),
    ...(gate?.recent_events ?? [])
      .filter(event => event.channel === (connector?.channel ?? ''))
      .map(event => event.room_id),
    ...configuredBindings.map(binding => binding.channel_id),
  ])

  const bindingsByKeeper = new Map<string, Array<{ channel_id: string; keeper_name: string }>>()
  for (const binding of configuredBindings) {
    const existing = bindingsByKeeper.get(binding.keeper_name)
    if (existing) {
      existing.push(binding)
    } else {
      bindingsByKeeper.set(binding.keeper_name, [binding])
    }
  }
  const knownNames = new Set(keepers.map(keeper => keeper.name))
  const knownGroups: KeeperGroup[] = keepers.map(keeper => ({
    name: keeper.name,
    keeper,
    bindings: bindingsByKeeper.get(keeper.name) ?? [],
    unknown: false,
  }))
  const unknownGroups: KeeperGroup[] = []
  for (const [name, bindings] of bindingsByKeeper) {
    if (knownNames.has(name)) continue
    unknownGroups.push({ name, keeper: null, bindings, unknown: true })
  }

  const keeperQuery = ui.keeperGroupQuery
  const visibleKnownGroups = filterKeeperGroups(knownGroups, keeperQuery)
  const isFilteringKeepers = keeperQuery.trim() !== ''

  const browserDot: LivenessDot = {
    label: 'Browser → Server',
    state: connectorError ? 'down' : 'ok',
    detail: connectorError ? 'gate fetch failed' : 'live',
    hint: connectorError ? `Check server at ${connector?.gate_base_url || 'localhost:8935'}` : '',
  }
  const serverDot: LivenessDot = (() => {
    if (!connector?.available) {
      return {
        label: 'Server → Sidecar',
        state: 'down',
        detail: 'no status.json yet',
        hint: `Run ./run.sh from sidecars/${connectorId}-bot/`,
      }
    }
    if (connector.stale) {
      return {
        label: 'Server → Sidecar',
        state: 'warn',
        detail: `stale · last heartbeat ${timeAgo(connector.updated_at)}`,
        hint: 'Sidecar heartbeats stopped — tail its log',
      }
    }
    return {
      label: 'Server → Sidecar',
      state: 'ok',
      detail: `heartbeat ${timeAgo(connector.updated_at)}`,
      hint: '',
    }
  })()
  const sidecarDot: LivenessDot = (() => {
    if (!connector?.available) {
      return {
        label: `Sidecar → ${connectorName}`,
        state: 'unknown',
        detail: 'sidecar offline',
        hint: '',
      }
    }
    const advertised = connectorStateLabel(connector)
    if (advertised === 'connected') {
      return {
        label: `Sidecar → ${connectorName}`,
        state: 'ok',
        detail: connector.bot_user_name ? `as ${connector.bot_user_name}` : 'linked',
        hint: '',
      }
    }
    if (advertised === 'stale') {
      return {
        label: `Sidecar → ${connectorName}`,
        state: 'warn',
        detail: 'stale heartbeat',
        hint: 'Sidecar process may have stopped',
      }
    }
    return {
      label: `Sidecar → ${connectorName}`,
      state: 'warn',
      detail: 'gateway link not yet up',
      hint: 'Check token and network reachability',
    }
  })()
  const livenessDots: LivenessDot[] = [browserDot, serverDot, sidecarDot]

  const showNoKeeperEmpty =
    configuredBindings.length === 0 && !connector?.available && keepers.length === 0 && !keeperDirectoryError
  const showSidecarOffEmpty =
    !showNoKeeperEmpty && configuredBindings.length === 0 && !connector?.available

  const headerIcon = channelIcon(connector?.channel ?? connectorId)

  return html`
    <div id=${`connector-card-${connectorId}`} class=${`mb-4 scroll-mt-4 rounded border border-[var(--card-border)] ${connectorCardBorderClass(directLabel)} p-4`} data-connector-card-state=${directLabel} style=${connectorAccentStyle(connectorId)}>
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="text-base leading-none" aria-hidden="true">${headerIcon}</span>
        <span class="text-sm font-semibold text-[var(--text-body)]">${connectorName}</span>
        ${connector?.bot_user_name
          ? html`<span class="text-[var(--text-dim)]">· ${connector.bot_user_name}</span>`
          : null}
        <span class="text-[var(--text-dim)]">·</span>
        <span class=${`inline-flex items-center gap-1.5 rounded-sm border px-2 py-0.5 text-3xs uppercase tracking-4 ${directTone}`}>
          <span class=${`inline-block h-2 w-2 rounded-full ${dotClassForLabel(directLabel)}`}></span>
          <span>${directLabel}</span>
        </span>
        <span class="text-[var(--text-dim)]">· hb ${timeAgo(connector?.updated_at ?? '')}</span>
        ${connector?.reply_mode
          ? html`<span class="text-[var(--text-dim)]">· reply ${connector.reply_mode}</span>`
          : null}
        ${connector?.self_chat_guid
          ? html`<span class="text-[var(--text-dim)]">· self-chat ${truncateMiddle(connector.self_chat_guid, 28)}</span>`
          : null}
        <span class="ml-auto flex items-center gap-2">
          ${connector?.available
            ? html`
                <button
                  type="button"
                  class="cursor-pointer rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-0.5 text-3xs uppercase tracking-4 text-[var(--bad-light)] hover:bg-[var(--bad-10)] disabled:opacity-50"
                  disabled=${isActionLoading}
                  aria-label=${`stop ${connectorName} sidecar`}
                  onClick=${() => { void stopSidecar(connectorId) }}
                >${isActionLoading ? '…' : 'Stop'}</button>
              `
            : null}
          <${SidecarLogToggle} connectorId=${connectorId} />
          <${ConnectorConfigToggle} connectorId=${connectorId} />
          ${sidecarLogPath
            ? html`<span class="cursor-help text-3xs text-[var(--text-dim)]" title=${sidecarLogPath}>↗</span>`
            : null}
          <button
            type="button"
            class="cursor-pointer rounded border border-[var(--card-border)] px-1.5 text-2xs text-[var(--text-dim)] hover:text-[var(--text-body)]"
            aria-label="toggle header details"
            onClick=${() => { patchConnectorUiState(connectorId, { headerExpanded: !ui.headerExpanded }) }}
          >${ui.headerExpanded ? '▴' : '▾'}</button>
        </span>
      </div>

      <${ConnectorReadinessRail}
        pills=${deriveRail(
          {
            sidecarUp: connector?.available === true,
            gateHealthy: connector?.gate_healthy ?? null,
            bindingCount: configuredBindings.length,
            keeperCount: keepers.length,
          },
          {
            openConfig: () => openConnectorConfig(connectorId),
            toggleProcess: () => {
              const isUp = connector?.available === true
              void withRailInflight(connectorId, 'process', () =>
                isUp ? stopSidecar(connectorId) : startSidecar(connectorId),
              )
            },
            expandHeader: () => { patchConnectorUiState(connectorId, { headerExpanded: true }) },
            scrollToBindings: () => {
              const el = document.getElementById(`keepers-${connectorId}`)
              if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
            },
          },
          getRailInflight(connectorId),
        )}
      />

      <${StartupCheckBanner} connectorId=${connectorId} sidecarUp=${connector?.available === true} />

      ${connector?.available === true && configuredBindings.length === 0 && keepers.length > 0
        ? html`<${QuickBindForm} connectorId=${connectorId} keepers=${keepers} />`
        : null}

      ${ui.headerExpanded
        ? html`
            <div class="mt-2 rounded border border-[var(--card-border)] bg-[var(--white-4)] p-3 text-2xs">
              <div class="space-y-1.5">
                ${livenessDots.map(dot => html`
                  <div class="flex min-w-0 flex-wrap items-center gap-2">
                    <span class=${`inline-block h-2 w-2 rounded-full ${dotClass(dot.state)}`}></span>
                    <span class="font-medium">${dot.label}</span>
                    <span class="text-[var(--text-dim)]">${dot.detail}</span>
                    ${dot.hint && (dot.state === 'down' || dot.state === 'warn')
                      ? html`<span class="italic text-[var(--text-dim)]">— ${dot.hint}</span>`
                      : null}
                  </div>
                `)}
              </div>
              <div class="mt-3 flex flex-wrap gap-3 text-3xs text-[var(--text-dim)]">
                <span>guilds ${connector?.guild_count ?? 0}</span>
                <span>gate ${gateHealthLabel}</span>
                <span>source ${connector?.binding_source || 'unknown'}</span>
                <span>runtime bindings ${connector?.runtime_bindings_count ?? configuredBindings.length}</span>
                <span>keeper dir ${keepers.length}</span>
              </div>
              <div class="mt-3">
                <${ActionButton} variant="ghost" size="sm" disabled=${loading || isActionLoading} onClick=${() => { void refresh() }}>Refresh<//>
              </div>
            </div>
          `
        : null}

      ${connectorError || connector?.error
        ? html`
            <div class="mt-3 rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--warn)]" data-connector-warning-panel>
              <div class="font-semibold text-[var(--text-body)]">
                ${connectorError ? 'Connector API unavailable' : 'Sidecar status warning'}
              </div>
              <div class="mt-1">
                <span class="font-medium">Cause: </span> ${connectorError ?? connector?.error}
              </div>
              <div class="mt-1">
                <span class="font-medium">Next: </span>
                ${connectorError
                  ? html`refresh the dashboard or check <code class="rounded bg-[var(--white-4)] px-1">/api/v1/gate/connectors</code> on ${connector?.gate_base_url || 'the Gate server'}.`
                  : html`run the ${connectorName} status command and inspect <code class="rounded bg-[var(--white-4)] px-1">${connector?.status_path || `sidecars/${connectorId}-bot/status.json`}</code>.`}
              </div>
            </div>
          `
        : null}

      <${SidecarLogViewer} connectorId=${connectorId} />
      <${ConnectorConfigForm} connectorId=${connectorId} />

      ${keeperDirectoryError && keepers.length === 0
        ? html`
            <div
              class="mt-3 rounded border border-[var(--warn-20)] border-l-4 border-l-amber-500 bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--warn)]"
              data-keeper-directory-error-panel
            >
              <span
                class="mr-2 inline-flex items-center gap-1 rounded-sm border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--warn)]"
                aria-label="Keeper directory status: unavailable"
              >
                <span aria-hidden="true">⚠</span>
                <span>Directory error</span>
              </span>
              ${connector?.gate_health_checked_at
                ? html`<span class="text-3xs text-[var(--text-dim)]">checked ${timeAgo(connector.gate_health_checked_at)}</span>`
                : null}
              <div class="mt-1">
                <span class="font-medium">Cause: </span> keeper directory unavailable, manual entry only.
              </div>
              <div class="mt-1">
                <span class="font-medium">Next: </span> continue with manual entry now, then restore <code class="rounded bg-[var(--white-4)] px-1">config/keepers/</code> or fix <code class="rounded bg-[var(--white-4)] px-1">/api/v1/gate/keepers</code> before relying on directory suggestions.
              </div>
            </div>
          `
        : null}

      ${showNoKeeperEmpty
        ? html`
            <div
              class="mt-3 rounded border border-dashed border-[var(--warn-20)] border-l-4 border-l-amber-500 bg-[var(--warn-10)] px-3 py-3 text-xs"
              data-no-keepers-empty-panel
            >
              <div class="mb-1 flex items-center gap-2">
                <span
                  class="inline-flex items-center gap-1 rounded-sm border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--warn)]"
                  aria-label="Keeper configuration status: none configured"
                  data-no-keepers-status-chip
                >
                  <span aria-hidden="true">⊘</span>
                  <span>Not configured</span>
                </span>
                <span class="font-medium text-[var(--text-body)]">No keepers configured</span>
              </div>
              <div class="text-3xs text-[var(--warn)]/80">
                Add keeper config files under <code class="rounded bg-[var(--white-4)] px-1">config/keepers/</code> and restart the server.
              </div>
            </div>
          `
        : null}

      ${showSidecarOffEmpty
        ? (() => {
            const cmds = sidecarCommands(connectorId)
            const copyLabels = {
              start: `Copy ${connectorName} sidecar start command`,
              tail: `Copy ${connectorName} sidecar tail logs command`,
              status: `Copy ${connectorName} sidecar status command`,
              stop: `Copy ${connectorName} sidecar stop command`,
            }
            // Informational amber tone (Railway / Vercel idle-service
            // convention): "needs action, not broken". Earlier this
            // panel inherited the connector accent gradient (iMessage =
            // green), which visually read as "success" on a card that
            // wasn't running. Amber overrides the accent bleed-through
            // with an explicit "please click Start" signal. The left
            // stripe matches the Portainer status-border pattern used
            // on the outer card for vertical scannability.
            return html`
              <div
                class="mt-3 rounded border border-dashed border-[var(--warn-20)] border-l-4 border-l-amber-500 bg-[var(--warn-10)] px-3 py-3 text-xs"
                data-sidecar-not-started-panel
              >
                <div class="mb-1 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div class="flex flex-wrap items-center gap-2">
                    <span
                      class="inline-flex items-center gap-1 rounded-sm border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--warn)]"
                      aria-label="Sidecar process status: not running"
                      data-sidecar-status-chip
                    >
                      <span aria-hidden="true">⊘</span>
                      <span>Not running</span>
                    </span>
                    <span class="font-medium text-[var(--text-body)]">Sidecar not started</span>
                    ${connector?.updated_at
                      ? html`<span class="text-3xs text-[var(--text-dim)]">last seen ${timeAgo(connector.updated_at)}</span>`
                      : null}
                  </div>
                  <div class="flex flex-wrap items-center gap-2 sm:justify-end">
                    <${ActionButton}
                      variant="primary"
                      size="sm"
                      disabled=${isActionLoading}
                      onClick=${() => { void startSidecar(connectorId) }}
                    >${isActionLoading ? '...' : 'Start'}<//>
                    <span class="text-3xs uppercase tracking-4 text-[var(--text-dim)]">${connectorName}</span>
                  </div>
                </div>
                <div class="text-2xs text-[var(--warn)]/80">
                  <div>
                    <span class="font-medium">Cause: </span> no sidecar status file has been observed at <code class="rounded bg-[var(--white-4)] px-1">${connector?.status_path || `sidecars/${connectorId}-bot/status.json`}</code>.
                  </div>
                  <div class="mt-1">
                    <span class="font-medium">Next: </span> click <strong>Start</strong> to spawn via the backend, or copy the command below to run it from a terminal. Use <strong>status</strong> and <strong>tail logs</strong> if it stays offline.
                  </div>
                </div>
                <div class="mt-2 grid grid-cols-1 gap-1.5">
                  <${CopyableCode}
                    label="start"
                    command=${cmds.start}
                    ariaLabel=${copyLabels.start}
                    variant="primary"
                  />
                </div>
                <div class="mt-2">
                  <div class="mb-1 text-3xs uppercase tracking-4 text-[var(--text-dim)]">
                    Or for diagnostics
                  </div>
                  <div class="grid grid-cols-1 gap-1.5" data-sidecar-secondary-cmds>
                    <${CopyableCode}
                      label="tail logs"
                      command=${cmds.tail}
                      ariaLabel=${copyLabels.tail}
                      variant="secondary"
                    />
                    <${CopyableCode}
                      label="status"
                      command=${cmds.status}
                      ariaLabel=${copyLabels.status}
                      variant="secondary"
                    />
                    <${CopyableCode}
                      label="stop"
                      command=${cmds.stop}
                      ariaLabel=${copyLabels.stop}
                      variant="secondary"
                    />
                  </div>
                </div>
                <${SetupGuideCard} connectorId=${connectorId} />
              </div>
            `
          })()
        : null}

      ${knownGroups.length > 0
        ? html`
            <div class="mt-3 space-y-2" id=${`keepers-${connectorId}`}>
              <div class="flex items-center justify-end">
                <input
                  type="search"
                  value=${keeperQuery}
                  placeholder="keeper / model / runtime 필터"
                  aria-label="Keeper 필터"
                  data-testid=${`keeper-filter-${connectorId}`}
                  onInput=${(e: Event) => { patchConnectorUiState(connectorId, { keeperGroupQuery: (e.target as HTMLInputElement).value }) }}
                  class="min-w-40 max-w-65 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
                />
              </div>
              ${isFilteringKeepers && visibleKnownGroups.length === 0
                ? html`<div class="py-4 text-center text-2xs text-[var(--text-dim)]">필터 결과 없음 (${knownGroups.length} keepers)</div>`
                : null}
              ${visibleKnownGroups.map(group => {
                const keeper = group.keeper
                const expanded = ui.expandedKeeperFor === group.name
                const toggleExpand = () => {
                  if (expanded) {
                    patchConnectorUiState(connectorId, { expandedKeeperFor: null })
                  } else {
                    patchConnectorUiState(connectorId, {
                      expandedKeeperFor: group.name,
                      channelDraft: '',
                    })
                  }
                }
                return html`
                  <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] px-3 py-2" data-keeper=${group.name}>
                    <div class="flex flex-wrap items-baseline gap-3">
                      <div class="text-sm font-medium text-[var(--text-body)]">${group.name}</div>
                      ${keeper
                        ? html`
                            <div class="text-3xs text-[var(--text-dim)]">
                              status ${keeper.status || 'unknown'}
                              ${modelLabelForKeeper(keeper) ? ` · model ${modelLabelForKeeper(keeper)}` : ''}
                              ${runtimeLabelForKeeper(keeper) ? ` · runtime ${runtimeLabelForKeeper(keeper)}` : ''}
                            </div>
                          `
                        : null}
                    </div>

                    ${group.bindings.length === 0
                      ? html`<div class="mt-1 text-2xs text-[var(--text-dim)]">(no channels)</div>`
                      : html`
                          <div class="mt-2 space-y-1">
                            ${group.bindings.map(binding => {
                              const humanized = humanizeChannel(names, binding.channel_id)
                              return html`
                                <div class="flex items-center justify-between gap-3 text-xs" data-channel-id=${binding.channel_id}>
                                  <div class="min-w-0 text-[var(--text-body)]">
                                    <span class="mr-1 text-[var(--text-dim)]">·</span>
                                    ${humanized
                                      ? html`<span>${humanized}</span>`
                                      : html`<span class="text-[var(--text-dim)]" title="sidecar has not sent names yet">names pending</span>`}
                                    <span class="ml-2 text-3xs text-[var(--text-dim)]">(${truncateMiddle(binding.channel_id, 14)})</span>
                                  </div>
                                  ${bindingActionsEnabled
                                    ? html`
                                        <${ActionButton}
                                          variant="ghost"
                                          size="sm"
                                          disabled=${isActionLoading}
                                          ariaLabel=${`unbind ${binding.channel_id}`}
                                          onClick=${() => { void unbindConnector(connectorId, binding.channel_id) }}
                                        >unbind<//>
                                      `
                                    : null}
                                </div>
                              `
                            })}
                          </div>
                        `}

                    ${bindingActionsEnabled
                      ? html`
                          <div class="mt-2">
                            <button
                              type="button"
                              class="cursor-pointer text-2xs text-[var(--text-dim)] hover:text-[var(--text-body)]"
                              aria-label=${`add channel to ${group.name}`}
                              onClick=${toggleExpand}
                            >${expanded ? '− close' : '+ add channel'}</button>
                          </div>
                          ${expanded
                            ? html`
                                <div class="mt-2 rounded border border-dashed border-[var(--card-border)] bg-[var(--white-3)] p-2">
                                  <${TextInput}
                                    value=${ui.channelDraft}
                                    placeholder=${`Paste ${connectorName} channel ID — right-click a channel → Copy ID`}
                                    ariaLabel=${`${connectorName} channel id`}
                                    onInput=${(e: Event) => { patchConnectorUiState(connectorId, { channelDraft: (e.target as HTMLInputElement).value }) }}
                                  />
                                  ${ui.channelDraft.trim() && humanizeChannel(names, ui.channelDraft.trim())
                                    ? html`<div class="mt-1 text-3xs text-[var(--text-dim)]">resolves to ${humanizeChannel(names, ui.channelDraft.trim())}</div>`
                                    : null}
                                  ${observedRooms.length > 0
                                    ? html`
                                        <div class="mt-2 flex flex-wrap gap-1.5">
                                          ${observedRooms.slice(0, 8).map(roomId => {
                                            const humanized = humanizeChannel(names, roomId)
                                            return html`
                                              <button
                                                type="button"
                                                class="cursor-pointer rounded-sm border border-[var(--card-border)] bg-[var(--white-4)] px-2 py-0.5 text-3xs text-[var(--text-body)] hover:bg-[var(--white-8)]"
                                                title=${roomId}
                                                onClick=${() => { patchConnectorUiState(connectorId, { channelDraft: roomId }) }}
                                              >${humanized
                                                ? html`<span>${humanized}</span><span class="ml-1 text-[var(--text-dim)]">· ${truncateMiddle(roomId, 10)}</span>`
                                                : truncateMiddle(roomId, 22)}</button>
                                            `
                                          })}
                                        </div>
                                      `
                                    : null}
                                  <div class="mt-2 flex justify-end">
                                    <${ActionButton}
                                      variant="primary"
                                      size="sm"
                                      disabled=${isActionLoading || ui.channelDraft.trim().length === 0}
                                      onClick=${() => { void bindConnector(connectorId, group.name, ui.channelDraft.trim()) }}
                                    >${isActionLoading ? 'Applying...' : 'bind'}<//>
                                  </div>
                                </div>
                              `
                            : null}
                        `
                      : null}
                  </div>
                `
              })}
            </div>
          `
        : null}

      ${unknownGroups.length > 0
        ? html`
            <div class="mt-3 space-y-2">
              ${unknownGroups.map(group => html`
                <div class="rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2" data-keeper=${group.name}>
                  <div class="flex items-baseline gap-2">
                    <span class="text-[var(--warn)]">⚠</span>
                    <div class="min-w-0">
                      <div class="text-sm font-medium text-[var(--text-body)]">${group.name}</div>
                      <div class="text-3xs text-[var(--warn)]/90">binding references undefined keeper</div>
                    </div>
                  </div>
                  <div class="mt-2 space-y-1">
                    ${group.bindings.map(binding => {
                      const humanized = humanizeChannel(names, binding.channel_id)
                      return html`
                        <div class="flex items-center justify-between gap-3 text-xs" data-channel-id=${binding.channel_id}>
                          <div class="min-w-0 text-[var(--text-body)]">
                            <span class="mr-1 text-[var(--text-dim)]">·</span>
                            ${humanized
                              ? html`<span>${humanized}</span>`
                              : html`<span class="text-[var(--text-dim)]">names pending</span>`}
                            <span class="ml-2 text-3xs text-[var(--text-dim)]">(${truncateMiddle(binding.channel_id, 14)})</span>
                          </div>
                          ${bindingActionsEnabled
                            ? html`
                                <${ActionButton}
                                  variant="ghost"
                                  size="sm"
                                  disabled=${isActionLoading}
                                  ariaLabel=${`unbind ${binding.channel_id}`}
                                  onClick=${() => { void unbindConnector(connectorId, binding.channel_id) }}
                                >unbind<//>
                              `
                            : null}
                        </div>
                      `
                    })}
                  </div>
                </div>
              `)}
            </div>
          `
        : null}

      ${connector
        ? html`
            <div class="mt-4 flex flex-wrap gap-3 text-3xs text-[var(--text-dim)]">
              ${connector.status_path
                ? html`<span title=${connector.status_path}>runtime ${truncateMiddle(connector.status_path, 50)}</span>`
                : null}
              ${sidecarLogPath
                ? html`<span title=${sidecarLogPath}>logs ${truncateMiddle(sidecarLogPath, 50)}</span>`
                : null}
            </div>
          `
        : null}
    </div>
  `
}

function ChannelCard({ ch }: { ch: ChannelInfo }) {
  const tone = healthTone(ch.health)
  const lastError = shortText(ch.last_error)

  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] p-3">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-lg">${channelIcon(ch.channel)}</span>
          <div>
            <div class="text-sm font-medium text-[var(--text-body)]">${ch.channel}</div>
            <div class="text-3xs uppercase tracking-[0.18em] text-[var(--text-dim)]">
              ${ch.last_keeper ? `keeper ${ch.last_keeper}` : 'no keeper yet'}
            </div>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <div class="h-2 w-2 rounded-full" style="background: ${tone.dot}"></div>
          <span class=${`rounded-sm px-2 py-1 text-3xs uppercase tracking-5 ${tone.badge}`}>
            ${tone.label}
          </span>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-2 text-xs">
        <div>
          <div class="text-[var(--text-dim)]">messages</div>
          <div class="font-mono text-[var(--text-body)]">${ch.message_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">success</div>
          <div class="font-mono text-[var(--text-body)]">${ch.success_rate_pct}%</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">errors</div>
          <div class="font-mono text-[var(--text-body)]">${ch.error_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">duplicates</div>
          <div class="font-mono text-[var(--text-body)]">${ch.duplicate_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">namespaces</div>
          <div class="font-mono text-[var(--text-body)]">${ch.room_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">last active</div>
          <div class="font-mono text-[var(--text-body)]">${timeAgo(ch.last_activity)}</div>
        </div>
      </div>

      <div class="mt-3 grid grid-cols-2 gap-2 text-2xs text-[var(--text-dim)]">
        <div>
          avg ${(ch.avg_duration_ms / 1000).toFixed(1)}s
          <span class="text-[var(--text-dim)]"> / max ${(ch.max_duration_ms / 1000).toFixed(1)}s</span>
        </div>
        <div>
          slow ${ch.slow_count}
          <span class="text-[var(--text-dim)]"> (${ch.slow_rate_pct}%)</span>
        </div>
        <div>
          last outcome
          <span class="font-mono text-[var(--text-body)]"> ${ch.last_outcome}</span>
        </div>
        <div>
          last namespace
          <span class="font-mono text-[var(--text-body)]"> ${ch.last_room_id || '-'}</span>
        </div>
      </div>

      ${lastError
        ? html`
            <div class="mt-3 rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-2xs text-[var(--bad-light)]">
              <div class="mb-1 uppercase tracking-5 text-[var(--bad-light)]/80">
                ${ch.last_error_kind || 'error'} · ${timeAgo(ch.last_error_at)}
              </div>
              <div>${lastError}</div>
            </div>
          `
        : null}
    </div>
  `
}

function BindingRow({ binding }: { binding: BindingInfo }) {
  const tone = healthTone(binding.health)
  const lastError = shortText(binding.last_error, 72)

  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] px-3 py-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-xs font-medium text-[var(--text-body)]">
            ${binding.channel} · room ${truncateMiddle(binding.room_id)}
          </div>
          <div class="text-3xs uppercase tracking-5 text-[var(--text-dim)]">
            ${binding.keeper ? `keeper ${binding.keeper}` : 'keeper pending'}
          </div>
        </div>
        <span class=${`rounded-sm px-2 py-1 text-3xs uppercase tracking-5 ${tone.badge}`}>
          ${tone.label}
        </span>
      </div>
      <div class="mt-2 grid grid-cols-3 gap-2 text-2xs text-[var(--text-dim)]">
        <div>
          msgs <span class="font-mono text-[var(--text-body)]">${binding.message_count}</span>
        </div>
        <div>
          success <span class="font-mono text-[var(--text-body)]">${binding.success_rate_pct}%</span>
        </div>
        <div>
          last <span class="font-mono text-[var(--text-body)]">${binding.last_outcome}</span>
        </div>
      </div>
      <div class="mt-1 text-2xs text-[var(--text-dim)]">
        recent activity <span class="font-mono text-[var(--text-body)]">${timeAgo(binding.last_activity)}</span>
      </div>
      ${lastError
        ? html`
            <div class="mt-2 rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-1 text-3xs text-[var(--bad-light)]">
              ${binding.last_error_kind || 'error'} · ${lastError}
            </div>
          `
        : null}
    </div>
  `
}

function EventRow({ event }: { event: GateEventInfo }) {
  const isError = Boolean(event.error)
  const badgeClass = isError
    ? 'border border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]'
    : 'border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-dim)]'

  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] px-3 py-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 text-2xs text-[var(--text-dim)]">
          <div class="font-medium text-[var(--text-body)]">
            ${event.channel} · ${event.keeper || 'unassigned'} · room ${truncateMiddle(event.room_id)}
          </div>
          <div class="mt-1">
            ${timeAgo(event.timestamp)}
            ${event.duration_ms > 0
              ? html`<span class="ml-2 font-mono">${(event.duration_ms / 1000).toFixed(1)}s</span>`
              : null}
          </div>
        </div>
        <span class=${`rounded-sm px-2 py-1 text-3xs uppercase tracking-5 ${badgeClass}`}>
          ${event.outcome}
        </span>
      </div>
      ${event.error
        ? html`
            <div class="mt-2 text-3xs text-[var(--bad-light)]">
              ${event.error_kind || 'error'} · ${shortText(event.error, 96)}
            </div>
          `
        : null}
    </div>
  `
}

function DisclosurePanel({
  title,
  subtitle,
  children,
  testId,
}: {
  title: string
  subtitle: string
  children: ComponentChildren
  testId: string
}) {
  return html`
    <details class="mb-4 rounded border border-[var(--card-border)] bg-[var(--bg-1)]" data-testid=${testId}>
      <summary class="cursor-pointer list-none px-3 py-2.5">
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--text-body)]">${title}</div>
            <div class="mt-1 text-2xs text-[var(--text-dim)]">${subtitle}</div>
          </div>
          <span class="text-2xs text-[var(--text-dim)]">펴기</span>
        </div>
      </summary>
      <div class="border-t border-[var(--card-border)] px-3 py-3">
        ${children}
      </div>
    </details>
  `
}

function GateAnalyticsSection({
  gate,
  gateError,
}: {
  gate: GateStatusData | null
  gateError: string | null
}) {
  let subtitle = '메시지, 에러, 최근 이벤트와 room binding을 필요할 때만 펼쳐 봅니다.'
  if (gateError) {
    subtitle = `Gate metrics unavailable: ${gateError}`
  } else if (gate === null) {
    subtitle = 'Gate-observed traffic is not available yet.'
  }

  return html`
    <${DisclosurePanel}
      title="게이트 분석"
      subtitle=${subtitle}
      testId="connector-gate-analytics"
    >
      ${gate === null
        ? html`
            <div class="rounded border border-dashed border-[var(--card-border)] px-3 py-4 text-xs text-[var(--text-dim)]">
              게이트가 광고하는 connector runtime 은 보이지만, 게이트가 관찰한 트래픽 은 아직 없습니다.
            </div>
          `
        : html`
            <div>
              <div class="mb-3 grid grid-cols-4 gap-2 max-[720px]:grid-cols-2">
                <${StatCard} label="메시지" value=${gate.total_messages} />
                <${StatCard} label="성공" value=${gate.total_success} />
                <${StatCard} label="오류" value=${gate.total_errors} />
                <${StatCard} label="중복 제거 키" value=${gate.dedup_table_size} />
              </div>

              <div class="mb-4 grid grid-cols-2 gap-2 text-2xs text-[var(--text-dim)] max-[720px]:grid-cols-1">
                <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] px-3 py-2">
                  duplicate suppressions
                  <span class="ml-2 font-mono text-[var(--text-body)]">${gate.total_duplicates}</span>
                </div>
                <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] px-3 py-2">
                  active connectors
                  <span class="ml-2 font-mono text-[var(--text-body)]">${gate.channels.length}</span>
                </div>
              </div>

              <div class="mb-4 grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
                <div>
                  <div class="mb-2 text-3xs uppercase tracking-5 text-[var(--text-dim)]">
                    Observed room bindings
                  </div>
                  ${gate.bindings.length === 0
                    ? html`<div class="rounded border border-dashed border-[var(--card-border)] px-3 py-4 text-xs text-[var(--text-dim)]">관찰된 room 바인딩 없음</div>`
                    : html`
                        <div class="space-y-2">
                          ${gate.bindings.slice(0, 6).map(binding => html`<${BindingRow} binding=${binding} />`)}
                        </div>
                      `}
                </div>

                <div>
                  <div class="mb-2 text-3xs uppercase tracking-5 text-[var(--text-dim)]">
                    Recent gate events
                  </div>
                  ${gate.recent_events.length === 0
                    ? html`<div class="rounded border border-dashed border-[var(--card-border)] px-3 py-4 text-xs text-[var(--text-dim)]">커넥터 이벤트 기록 없음</div>`
                    : html`
                        <div class="space-y-2">
                          ${gate.recent_events.slice(0, 8).map(event => html`<${EventRow} event=${event} />`)}
                        </div>
                      `}
                </div>
              </div>

              ${gate.channels.length === 0
                ? html`<div class="py-4 text-center text-xs text-[var(--text-dim)]">활성 커넥터 없음</div>`
                : html`
                    <div class="grid grid-cols-2 gap-2 max-[900px]:grid-cols-1">
                      ${gate.channels.map(ch => html`<${ChannelCard} ch=${ch} />`)}
                    </div>
                  `}
            </div>
          `}
    <//>
  `
}

export function ConnectorStatusPanel() {
  useEffect(() => {
    void refresh()
    return () => { connectorStatusResource.cancel() }
  }, [])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    const unsubscribe = lastEvent.subscribe((event) => {
      if (!event || !connectorStatusResource.state.value.data?.gate) return
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => {
        void refresh()
      }, 2000)
    })
    return () => {
      if (timer) clearTimeout(timer)
      unsubscribe()
    }
  }, [])

  const snapshot = connectorStatusResource.state.value.data ?? EMPTY_SNAPSHOT
  const loading = connectorStatusResource.state.value.loading
  const d = snapshot.gate
  const allConnectors = snapshot.connectors?.connectors ?? []
  const filterId = activeConnectorFilter()
  const visibleConnectors = filterId
    ? allConnectors.filter(c => c.connector_id === filterId)
    : allConnectors

  if (loading && !d && visibleConnectors.length === 0) {
    // Shape-matched skeleton (Vercel / Linear convention) — shows the
    // 4-tile grid layout so the operator can anticipate where content
    // will land instead of staring at a generic spinner.
    return html`<${ConnectorOverviewSkeleton} testId="connector-status-loading" />`
  }

  if (snapshot.gateError && !d && visibleConnectors.length === 0) {
    return html`<${ErrorState} message=${`Gate: ${snapshot.gateError}`} />`
  }

  if (filterId && allConnectors.length > 0 && visibleConnectors.length === 0) {
    return html`
      <div class="rounded border border-dashed border-[var(--white-8)] px-3 py-6 text-center text-xs text-[var(--text-dim)]">
        ${filterId} sidecar가 아직 Gate에 등록되지 않았습니다. 시작 후 다시 확인하세요.
      </div>
    `
  }

  if (!d && visibleConnectors.length === 0) {
    // Cold start: gate has not advertised any connector yet, and no per-bridge
    // filter is active. Surface the 4-card onboarding grid so a new operator
    // sees what bridges exist and how to start each one.
    if (!filterId) return html`<${ConnectorOnboardingGrid} />`
    return null
  }

  const focusedConnectorId = filterId
    ? filterId as KnownConnectorId
    : resolveConnectorFocusId(allConnectors, snapshot.keepers.length, selectedConnectorId.value)
  const focusedConnector = filterId
    ? visibleConnectors[0] ?? placeholderConnector(focusedConnectorId)
    : findKnownConnector(allConnectors, focusedConnectorId) ?? placeholderConnector(focusedConnectorId)

  return html`
    <div>
      <div class="mb-3 flex items-start justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold text-[var(--text-body)]">${filterId ? CONNECTOR_DISPLAY_NAMES[filterId as KnownConnectorId] ?? '커넥터' : '커넥터'}</h3>
          <div class="mt-1 text-2xs text-[var(--text-dim)]">
            ${filterId
              ? `${CONNECTOR_DISPLAY_NAMES[filterId as KnownConnectorId] ?? filterId} sidecar의 라이브 상태와 keeper 바인딩.`
              : '4종 채널 sidecar overview 카드에서 커넥터를 고르면 아래 상세 패널이 교체됩니다.'}
          </div>
        </div>
        ${filterId
          ? html`
              <div class="text-right text-3xs uppercase tracking-5 text-[var(--text-dim)]">
                <div>${d ? `success ${d.success_rate_pct}%` : `${visibleConnectors.length} connector${visibleConnectors.length !== 1 ? 's' : ''}`}</div>
                <div>${d ? `uptime ${formatUptime(d.uptime_seconds)}` : 'gate metrics unavailable'}</div>
              </div>
            `
          : null}
      </div>

      ${!filterId
        ? html`
            <${ConnectorOverviewStrip}
              connectors=${allConnectors}
              keeperCount=${snapshot.keepers.length}
              selectedConnectorId=${focusedConnectorId}
              onSelectConnector=${(connectorId: KnownConnectorId) => { selectedConnectorId.value = connectorId }}
              detailTargetId="connector-detail-panel"
            />
          `
        : null}

      ${!filterId
        ? html`
            <div
              id="connector-detail-panel"
              class="mb-4 rounded border border-[var(--card-border)] bg-[var(--bg-0)]/40 p-3"
              data-testid="connector-detail-panel"
            >
              <div class="mb-3 flex items-center justify-between gap-3 text-2xs">
                <div>
                  <span class="font-semibold text-[var(--text-body)]">${CONNECTOR_DISPLAY_NAMES[focusedConnectorId]}</span>
                  <span class="ml-2 text-[var(--text-dim)]">선택한 커넥터의 상세와 액션만 보여줍니다.</span>
                </div>
                <span class="text-[var(--text-dim)]">overview 카드에서 전환</span>
              </div>
              <${ConnectorLivePanel}
                connector=${focusedConnector}
                gate=${d}
                keepers=${snapshot.keepers}
                connectorError=${snapshot.connectorError}
                keeperDirectoryError=${snapshot.keeperError}
                loading=${loading}
              />
            </div>
          `
        : null}

      ${filterId
        ? html`
            <${ConnectorLivePanel}
              connector=${focusedConnector}
              gate=${d}
              keepers=${snapshot.keepers}
              connectorError=${snapshot.connectorError}
              keeperDirectoryError=${snapshot.keeperError}
              loading=${loading}
            />
          `
        : null}

      ${!filterId
        ? html`
            <${DisclosurePanel}
              title="키퍼 매트릭스"
              subtitle="cross-connector binding 현황은 필요할 때만 펼쳐 봅니다."
              testId="connector-matrix-disclosure"
            >
              <${ConnectorKeeperMatrix} matrix=${deriveMatrix(allConnectors, snapshot.keepers)} />
            <//>
          `
        : null}

      ${!filterId
        ? html`<${ConnectorPathsStrip} connectors=${allConnectors} />`
        : null}

      <${GateAnalyticsSection} gate=${d} gateError=${snapshot.gateError} />
    </div>
  `
}

export function resetConnectorStatusState() {
  connectorStatusResource.reset(EMPTY_SNAPSHOT)
  connectorUiState.value = {}
  selectedConnectorId.value = null
}

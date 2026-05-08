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
import { KpiStripIsland, type KpiStripIslandData } from './kpi-strip-island'
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
import { Tk } from './tk'

function MutedSpan({ children }: { children: unknown }) {
  return html`<span class="text-[var(--color-fg-disabled)]">${children}</span>`
}

function BoldLabel({ children }: { children: unknown }) {
  return html`<span class="font-medium">${children}</span>`
}

function CardBox({ children, dataKeeper }: { children: unknown; dataKeeper?: string }) {
  if (dataKeeper) {
    return html`<div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2" data-keeper=${dataKeeper}>${children}</div>`
  }
  return html`<div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">${children}</div>`
}

// As of 2026-04-30 the per-connector sub-tabs were merged into
// connector-status; selection now happens inside the page via
// ConnectorOverviewStrip rather than top-level navigation.
// `?connector=<id>` query parameter still narrows the view for deep links.
function activeConnectorFilter(): string | null {
  const connector = route.value.params.connector
  if (!connector) return null
  return KNOWN_CONNECTOR_IDS.includes(connector as KnownConnectorId) ? connector : null
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

const timeAgo = formatTimeAgoEn

function healthTone(health: string): { dot: string; badge: string; label: string } {
  switch (health) {
    case 'healthy':
      return {
        dot: 'var(--green)',
        badge: 'border border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]',
        label: 'healthy',
      }
    case 'degraded':
      return {
        dot: 'var(--yellow)',
        badge: 'border border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]',
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
        dot: 'var(--color-fg-disabled)',
        badge: 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)]',
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
      return 'bg-[var(--color-fg-disabled)]'
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
      return 'bg-[var(--color-fg-disabled)]'
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
      return 'border-l-4 border-l-[var(--color-warn)]'
    case 'disconnected':
      return 'border-l-4 border-l-rose-500'
    case 'offline':
    default:
      return 'border-l-4 border-l-[var(--color-border-default)]'
  }
}

function connectorStateTone(connector: GateConnectorInfo | null): string {
  const label = connectorStateLabel(connector)
  if (label === 'connected') {
    return 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]'
  }
  if (label === 'disconnected') {
    return 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]'
  }
  return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
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

async function unbindConnector(connectorId: string, channelId: string) {
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
    hint: connectorError ? `${connector?.gate_base_url || 'localhost:8935'} 에서 서버 확인` : '',
  }
  const serverDot: LivenessDot = (() => {
    if (!connector?.available) {
      return {
        label: 'Server → Sidecar',
        state: 'down',
        detail: '아직 status.json 없음',
        hint: `sidecars/${connectorId}-bot/ 에서 ./run.sh 실행`,
      }
    }
    if (connector.stale) {
      return {
        label: 'Server → Sidecar',
        state: 'warn',
        detail: `stale · last heartbeat ${timeAgo(connector.updated_at)}`,
        hint: 'Sidecar heartbeat 중단 — 로그 확인',
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
        detail: 'sidecar 오프라인',
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
        detail: 'heartbeat stale',
        hint: 'Sidecar 프로세스 중단 가능성',
      }
    }
    return {
      label: `Sidecar → ${connectorName}`,
      state: 'warn',
      detail: 'gateway link 미수립',
      hint: '토큰 및 네트워크 도달성 확인',
    }
  })()
  const livenessDots: LivenessDot[] = [browserDot, serverDot, sidecarDot]

  const showNoKeeperEmpty =
    configuredBindings.length === 0 && !connector?.available && keepers.length === 0 && !keeperDirectoryError
  const showSidecarOffEmpty =
    !showNoKeeperEmpty && configuredBindings.length === 0 && !connector?.available

  const headerIcon = channelIcon(connector?.channel ?? connectorId)

  return html`
    <div id=${`connector-card-${connectorId}`} class=${`mb-4 scroll-mt-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] ${connectorCardBorderClass(directLabel)} p-4`} data-connector-card-state=${directLabel} style=${connectorAccentStyle(connectorId)}>
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="text-base leading-none" aria-hidden="true">${headerIcon}</span>
        <span class="text-sm font-semibold text-[var(--color-fg-primary)]">${connectorName}</span>
        ${connector?.bot_user_name
          ? html`<${MutedSpan}><span aria-hidden="true">· </span>${connector.bot_user_name}</${MutedSpan}>`
          : null}
        <span class="text-[var(--color-fg-disabled)]" aria-hidden="true">·</span>
        <span class=${`inline-flex items-center gap-1.5 rounded-[var(--r-0)] border px-2 py-0.5 text-3xs uppercase tracking-4 ${directTone}`}>
          <span class=${`inline-block h-2 w-2 rounded-full ${dotClassForLabel(directLabel)}`}></span>
          <span>${directLabel}</span>
        </span>
        <${MutedSpan}><span aria-hidden="true">· </span>hb ${timeAgo(connector?.updated_at ?? '')}</${MutedSpan}>
        ${connector?.reply_mode
          ? html`<${MutedSpan}><span aria-hidden="true">· </span>reply ${connector.reply_mode}</${MutedSpan}>`
          : null}
        ${connector?.self_chat_guid
          ? html`<${MutedSpan}><span aria-hidden="true">· </span>self-chat ${truncateMiddle(connector.self_chat_guid, 28)}</${MutedSpan}>`
          : null}
        <span class="ml-auto flex items-center gap-2">
          ${connector?.available
            ? html`
                <button
                  type="button"
                  class="cursor-pointer rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-0.5 text-3xs uppercase tracking-4 text-[var(--bad-light)] hover:bg-[var(--bad-10)] disabled:opacity-50"
                  disabled=${isActionLoading}
                  aria-label=${`stop ${connectorName} sidecar`}
                  onClick=${() => { void stopSidecar(connectorId) }}
                >${isActionLoading ? '…' : 'Stop'}</button>
              `
            : null}
          <${SidecarLogToggle} connectorId=${connectorId} />
          <${ConnectorConfigToggle} connectorId=${connectorId} />
          ${sidecarLogPath
            ? html`<span class="cursor-help text-3xs text-[var(--color-fg-disabled)]" title=${sidecarLogPath} aria-hidden="true">↗</span>`
            : null}
          <button
            type="button"
            class="cursor-pointer rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 text-2xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)]"
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
            <div class="mt-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3 text-2xs">
              <div class="space-y-1.5">
                ${livenessDots.map(dot => html`
                  <div class="flex min-w-0 flex-wrap items-center gap-2">
                    <span class=${`inline-block h-2 w-2 rounded-full ${dotClass(dot.state)}`}></span>
                    <${BoldLabel}>${dot.label}</${BoldLabel}>
                    <${MutedSpan}>${dot.detail}</${MutedSpan}>
                    ${dot.hint && (dot.state === 'down' || dot.state === 'warn')
                      ? html`<span class="italic text-[var(--color-fg-disabled)]">— ${dot.hint}</span>`
                      : null}
                  </div>
                `)}
              </div>
              <div class="mt-3 flex flex-wrap gap-3 text-3xs text-[var(--color-fg-disabled)]">
                <span>guilds ${connector?.guild_count ?? 0}</span>
                <span>gate ${gateHealthLabel}</span>
                <span>source ${connector?.binding_source || 'unknown'}</span>
                <span>runtime bindings ${connector?.runtime_bindings_count ?? configuredBindings.length}</span>
                <span>keeper dir ${keepers.length}</span>
              </div>
              <div class="mt-3">
                <${ActionButton} variant="ghost" size="sm" disabled=${loading || isActionLoading} onClick=${() => { void refresh() }}>새로고침<//>
              </div>
            </div>
          `
        : null}

      ${connectorError || connector?.error
        ? html`
            <div class="mt-3 rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]" data-connector-warning-panel>
              <div class="font-semibold text-[var(--color-fg-primary)]">
                ${connectorError ? 'Connector API 사용 불가' : 'Sidecar 상태 경고'}
              </div>
              <div class="mt-1">
                <${BoldLabel}>Cause: </${BoldLabel}> ${connectorError ?? connector?.error}
              </div>
              <div class="mt-1">
                <${BoldLabel}>Next: </${BoldLabel}>
                ${connectorError
                  ? html`refresh the dashboard or check <${Tk}>/api/v1/gate/connectors<//> on ${connector?.gate_base_url || 'the Gate server'}.`
                  : html`run the ${connectorName} status command and inspect <${Tk}>${connector?.status_path || `sidecars/${connectorId}-bot/status.json`}<//>.`}
              </div>
            </div>
          `
        : null}

      <${SidecarLogViewer} connectorId=${connectorId} />
      <${ConnectorConfigForm} connectorId=${connectorId} />

      ${keeperDirectoryError && keepers.length === 0
        ? html`
            <div
              class="mt-3 rounded-[var(--r-1)] border border-[var(--warn-20)] border-l-4 border-l-[var(--color-warn)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]"
              data-keeper-directory-error-panel
            >
              <span
                class="mr-2 inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--color-status-warn)]"
                aria-label="키퍼 디렉토리 상태: 사용 불가"
              >
                <span aria-hidden="true">⚠</span>
                <span>디렉토리 오류</span>
              </span>
              ${connector?.gate_health_checked_at
                ? html`<span class="text-3xs text-[var(--color-fg-disabled)]">checked ${timeAgo(connector.gate_health_checked_at)}</span>`
                : null}
              <div class="mt-1">
                <${BoldLabel}>Cause: </${BoldLabel}> keeper 디렉토리 사용 불가, 수동 입력만 가능.
              </div>
              <div class="mt-1">
                <${BoldLabel}>Next: </${BoldLabel}> 지금은 수동 입력으로 진행, 이후 <${Tk}>config/keepers/<//> 복원 또는 <${Tk}>/api/v1/gate/keepers<//> 수정 후 디렉토리 추천에 의존하세요.
              </div>
            </div>
          `
        : null}

      ${showNoKeeperEmpty
        ? html`
            <div
              class="mt-3 rounded-[var(--r-1)] border border-dashed border-[var(--warn-20)] border-l-4 border-l-[var(--color-warn)] bg-[var(--warn-10)] px-3 py-3 text-xs"
              data-no-keepers-empty-panel
            >
              <div class="mb-1 flex items-center gap-2">
                <span
                  class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--color-status-warn)]"
                  aria-label="키퍼 설정 상태: 설정된 키퍼 없음"
                  data-no-keepers-status-chip
                >
                  <span aria-hidden="true">⊘</span>
                  <span>설정 필요</span>
                </span>
                <span class="font-medium text-[var(--color-fg-primary)]">설정된 키퍼 없음</span>
              </div>
              <div class="text-3xs text-[var(--color-status-warn)]/80">
                Add keeper config files under <${Tk}>config/keepers/<//> and restart the server.
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
                class="mt-3 rounded-[var(--r-1)] border border-dashed border-[var(--warn-20)] border-l-4 border-l-[var(--color-warn)] bg-[var(--warn-10)] px-3 py-3 text-xs"
                data-sidecar-not-started-panel
              >
                <div class="mb-1 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div class="flex flex-wrap items-center gap-2">
                    <span
                      class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--color-status-warn)]"
                      aria-label="사이드카 프로세스 상태: 실행 중 아님"
                      data-sidecar-status-chip
                    >
                      <span aria-hidden="true">⊘</span>
                      <span>실행 중 아님</span>
                    </span>
                    <span class="font-medium text-[var(--color-fg-primary)]">사이드카 미시작</span>
                    ${connector?.updated_at
                      ? html`<span class="text-3xs text-[var(--color-fg-disabled)]">last seen ${timeAgo(connector.updated_at)}</span>`
                      : null}
                  </div>
                  <div class="flex flex-wrap items-center gap-2 sm:justify-end">
                    <${ActionButton}
                      variant="primary"
                      size="sm"
                      disabled=${isActionLoading}
                      onClick=${() => { void startSidecar(connectorId) }}
                    >${isActionLoading ? '...' : 'Start'}<//>
                    <span class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">${connectorName}</span>
                  </div>
                </div>
                <div class="text-2xs text-[var(--color-status-warn)]/80">
                  사이드카 status 파일이 <${Tk}>${connector?.status_path || `sidecars/${connectorId}-bot/status.json`}<//> 에서 관찰되지 않았습니다.
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
                  <div class="mb-1 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">
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
                <${TextInput}
                  type="search"
                  value=${keeperQuery}
                  placeholder="keeper / model / runtime 필터"
                  ariaLabel="Keeper 필터"
                  testId=${`keeper-filter-${connectorId}`}
                  onInput=${(e: Event) => { patchConnectorUiState(connectorId, { keeperGroupQuery: (e.target as HTMLInputElement).value }) }}
                  class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
                />
              </div>
              ${isFilteringKeepers && visibleKnownGroups.length === 0
                ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${knownGroups.length} keepers)</div>`
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
                  <${CardBox} dataKeeper=${group.name}>
                    <div class="flex flex-wrap items-baseline gap-3">
                      <div class="text-sm font-medium text-[var(--color-fg-primary)]">${group.name}</div>
                      ${keeper
                        ? html`
                            <div class="text-3xs text-[var(--color-fg-disabled)]">
                              status ${keeper.status || 'unknown'}
                              ${modelLabelForKeeper(keeper) ? ` · model ${modelLabelForKeeper(keeper)}` : ''}
                              ${runtimeLabelForKeeper(keeper) ? ` · runtime ${runtimeLabelForKeeper(keeper)}` : ''}
                            </div>
                          `
                        : null}
                    </div>

                    ${group.bindings.length === 0
                      ? html`<div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">(no channels)</div>`
                      : html`
                          <div class="mt-2 space-y-1">
                            ${group.bindings.map(binding => {
                              const humanized = humanizeChannel(names, binding.channel_id)
                              return html`
                                <div class="flex items-center justify-between gap-3 text-xs" data-channel-id=${binding.channel_id}>
                                  <div class="min-w-0 text-[var(--color-fg-primary)]">
                                    <span class="mr-1 text-[var(--color-fg-disabled)]" aria-hidden="true">·</span>
                                    ${humanized
                                      ? html`<span>${humanized}</span>`
                                      : html`<span class="text-[var(--color-fg-disabled)]" title="sidecar has not sent names yet">names pending</span>`}
                                    <span class="ml-2 text-3xs text-[var(--color-fg-disabled)]">(${truncateMiddle(binding.channel_id, 14)})</span>
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
                              class="cursor-pointer text-2xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)]"
                              aria-label=${`add channel to ${group.name}`}
                              onClick=${toggleExpand}
                            >${expanded ? '− close' : '+ add channel'}</button>
                          </div>
                          ${expanded
                            ? html`
                                <div class="mt-2 rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
                                  <${TextInput}
                                    value=${ui.channelDraft}
                                    placeholder=${`Paste ${connectorName} channel ID — right-click a channel → Copy ID`}
                                    ariaLabel=${`${connectorName} channel id`}
                                    onInput=${(e: Event) => { patchConnectorUiState(connectorId, { channelDraft: (e.target as HTMLInputElement).value }) }}
                                  />
                                  ${ui.channelDraft.trim() && humanizeChannel(names, ui.channelDraft.trim())
                                    ? html`<div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">resolves to ${humanizeChannel(names, ui.channelDraft.trim())}</div>`
                                    : null}
                                  ${observedRooms.length > 0
                                    ? html`
                                        <div class="mt-2 flex flex-wrap gap-1.5">
                                          ${observedRooms.slice(0, 8).map(roomId => {
                                            const humanized = humanizeChannel(names, roomId)
                                            return html`
                                              <${ActionButton}
                                                variant="ghost"
                                                size="sm"
                                                class="!rounded-[var(--r-0)] !py-0.5"
                                                title=${roomId}
                                                ariaLabel=${humanized ? `select ${humanized}` : `select ${truncateMiddle(roomId, 22)}`}
                                                onClick=${() => { patchConnectorUiState(connectorId, { channelDraft: roomId }) }}
                                              >${humanized
                                                ? html`<span>${humanized}</span><span class="ml-1 text-[var(--color-fg-disabled)]"><span aria-hidden="true">· </span>${truncateMiddle(roomId, 10)}</span>`
                                                : truncateMiddle(roomId, 22)}<//>
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
                                    >${isActionLoading ? '적용 중...' : '연결'}<//>
                                  </div>
                                </div>
                              `
                            : null}
                        `
                      : null}
                  </${CardBox}>
                `
              })}
            </div>
          `
        : null}

      ${unknownGroups.length > 0
        ? html`
            <div class="mt-3 space-y-2">
              ${unknownGroups.map(group => html`
                <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2" data-keeper=${group.name}>
                  <div class="flex items-baseline gap-2">
                    <span class="text-[var(--color-status-warn)]">⚠</span>
                    <div class="min-w-0">
                      <div class="text-sm font-medium text-[var(--color-fg-primary)]">${group.name}</div>
                      <div class="text-3xs text-[var(--color-status-warn)]/90">binding references undefined keeper</div>
                    </div>
                  </div>
                  <div class="mt-2 space-y-1">
                    ${group.bindings.map(binding => {
                      const humanized = humanizeChannel(names, binding.channel_id)
                      return html`
                        <div class="flex items-center justify-between gap-3 text-xs" data-channel-id=${binding.channel_id}>
                          <div class="min-w-0 text-[var(--color-fg-primary)]">
                            <span class="mr-1 text-[var(--color-fg-disabled)]" aria-hidden="true">·</span>
                            ${humanized
                              ? html`<span>${humanized}</span>`
                              : html`<${MutedSpan}>names pending</${MutedSpan}>`}
                            <span class="ml-2 text-3xs text-[var(--color-fg-disabled)]">(${truncateMiddle(binding.channel_id, 14)})</span>
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
            <div class="mt-4 flex flex-wrap gap-3 text-3xs text-[var(--color-fg-disabled)]">
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
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-lg">${channelIcon(ch.channel)}</span>
          <div>
            <div class="text-sm font-medium text-[var(--color-fg-primary)]">${ch.channel}</div>
            <div class="text-3xs uppercase tracking-[var(--track-label)] text-[var(--color-fg-disabled)]">
              ${ch.last_keeper ? `keeper ${ch.last_keeper}` : 'no keeper yet'}
            </div>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <div class="h-2 w-2 rounded-full" style="background: ${tone.dot}"></div>
          <span class=${`rounded-[var(--r-0)] px-2 py-1 text-3xs uppercase tracking-5 ${tone.badge}`}>
            ${tone.label}
          </span>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-2 text-xs">
        <div>
          <div class="text-[var(--color-fg-disabled)]">messages</div>
          <div class="font-mono text-[var(--color-fg-primary)]">${ch.message_count}</div>
        </div>
        <div>
          <div class="text-[var(--color-fg-disabled)]">success</div>
          <div class="font-mono text-[var(--color-fg-primary)]">${ch.success_rate_pct}%</div>
        </div>
        <div>
          <div class="text-[var(--color-fg-disabled)]">errors</div>
          <div class="font-mono text-[var(--color-fg-primary)]">${ch.error_count}</div>
        </div>
        <div>
          <div class="text-[var(--color-fg-disabled)]">duplicates</div>
          <div class="font-mono text-[var(--color-fg-primary)]">${ch.duplicate_count}</div>
        </div>
        <div>
          <div class="text-[var(--color-fg-disabled)]">namespaces</div>
          <div class="font-mono text-[var(--color-fg-primary)]">${ch.room_count}</div>
        </div>
        <div>
          <div class="text-[var(--color-fg-disabled)]">last active</div>
          <div class="font-mono text-[var(--color-fg-primary)]">${timeAgo(ch.last_activity)}</div>
        </div>
      </div>

      <div class="mt-3 grid grid-cols-2 gap-2 text-2xs text-[var(--color-fg-disabled)]">
        <div>
          avg ${(ch.avg_duration_ms / 1000).toFixed(1)}s
          <${MutedSpan}> / max ${(ch.max_duration_ms / 1000).toFixed(1)}s</${MutedSpan}>
        </div>
        <div>
          slow ${ch.slow_count}
          <${MutedSpan}> (${ch.slow_rate_pct}%)</${MutedSpan}>
        </div>
        <div>
          last outcome
          <span class="font-mono text-[var(--color-fg-primary)]"> ${ch.last_outcome}</span>
        </div>
        <div>
          last namespace
          <span class="font-mono text-[var(--color-fg-primary)]"> ${ch.last_room_id || '-'}</span>
        </div>
      </div>

      ${lastError
        ? html`
            <div class="mt-3 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-2xs text-[var(--bad-light)]">
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
    <${CardBox}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-xs font-medium text-[var(--color-fg-primary)]">
            ${binding.channel} · room ${truncateMiddle(binding.room_id)}
          </div>
          <div class="text-3xs uppercase tracking-5 text-[var(--color-fg-disabled)]">
            ${binding.keeper ? `keeper ${binding.keeper}` : 'keeper pending'}
          </div>
        </div>
        <span class=${`rounded-[var(--r-0)] px-2 py-1 text-3xs uppercase tracking-5 ${tone.badge}`}>
          ${tone.label}
        </span>
      </div>
      <div class="mt-2 grid grid-cols-3 gap-2 text-2xs text-[var(--color-fg-disabled)]">
        <div>
          msgs <span class="font-mono text-[var(--color-fg-primary)]">${binding.message_count}</span>
        </div>
        <div>
          success <span class="font-mono text-[var(--color-fg-primary)]">${binding.success_rate_pct}%</span>
        </div>
        <div>
          last <span class="font-mono text-[var(--color-fg-primary)]">${binding.last_outcome}</span>
        </div>
      </div>
      <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
        recent activity <span class="font-mono text-[var(--color-fg-primary)]">${timeAgo(binding.last_activity)}</span>
      </div>
      ${lastError
        ? html`
            <div class="mt-2 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-1 text-3xs text-[var(--bad-light)]">
              ${binding.last_error_kind || 'error'} · ${lastError}
            </div>
          `
        : null}
    <//>
  `
}

function EventRow({ event }: { event: GateEventInfo }) {
  const isError = Boolean(event.error)
  const badgeClass = isError
    ? 'border border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]'
    : 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)]'

  return html`
    <${CardBox}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 text-2xs text-[var(--color-fg-disabled)]">
          <div class="font-medium text-[var(--color-fg-primary)]">
            ${event.channel} · ${event.keeper || 'unassigned'} · room ${truncateMiddle(event.room_id)}
          </div>
          <div class="mt-1">
            ${timeAgo(event.timestamp)}
            ${event.duration_ms > 0
              ? html`<span class="ml-2 font-mono">${(event.duration_ms / 1000).toFixed(1)}s</span>`
              : null}
          </div>
        </div>
        <span class=${`rounded-[var(--r-0)] px-2 py-1 text-3xs uppercase tracking-5 ${badgeClass}`}>
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
    <//>
  `
}

function DisclosurePanel({
  title,
  badge,
  children,
  testId,
}: {
  title: string
  badge?: ComponentChildren
  children: ComponentChildren
  testId: string
}) {
  return html`
    <details class="group mb-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]" data-testid=${testId}>
      <summary class="cursor-pointer list-none px-3 py-2.5">
        <div class="flex items-center justify-between gap-3">
          <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-primary)]">${title}</div>
          <div class="flex items-center gap-2 text-2xs text-[var(--color-fg-disabled)]">
            ${badge ?? null}
            <span aria-hidden="true" class="transition-transform group-open:rotate-180">▾</span>
          </div>
        </div>
      </summary>
      <div class="border-t border-[var(--color-border-default)] px-3 py-3">
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
  let badge: ComponentChildren = null
  if (gateError) {
    badge = html`<span class="text-[var(--color-status-err)]">메트릭 없음</span>`
  } else if (gate === null) {
    badge = html`<span>관찰된 트래픽 없음</span>`
  } else {
    badge = html`<span>메시지 ${gate.total_messages} · 오류 ${gate.total_errors}</span>`
  }

  return html`
    <${DisclosurePanel}
      title="게이트 분석"
      badge=${badge}
      testId="connector-gate-analytics"
    >
      ${gate === null
        ? html`
            <div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-4 text-xs text-[var(--color-fg-disabled)]">
              connector runtime은 등록됐으나 게이트가 관찰한 트래픽은 아직 없습니다.
            </div>
          `
        : html`
            <div>
              <div class="mb-3">
                <${KpiStripIsland}
                  ariaLabel="connector gate 통계"
                  cols=${4}
                  cells=${[
                    { variant: 'stacked', label: '메시지', value: gate.total_messages },
                    { variant: 'stacked', label: '성공', value: gate.total_success },
                    { variant: 'stacked', label: '오류', value: gate.total_errors },
                    { variant: 'stacked', label: '중복 제거 키', value: gate.dedup_table_size },
                  ] satisfies KpiStripIslandData['cells']}
                />
              </div>

              <div class="mb-4 grid grid-cols-2 gap-2 text-2xs text-[var(--color-fg-disabled)] max-[720px]:grid-cols-1">
                <${CardBox}>duplicate suppressions
                  <span class="ml-2 font-mono text-[var(--color-fg-primary)]">${gate.total_duplicates}</span>
                <//>
                <${CardBox}>active connectors
                  <span class="ml-2 font-mono text-[var(--color-fg-primary)]">${gate.channels.length}</span>
                <//>
              </div>

              <div class="mb-4 grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
                <div>
                  <div class="mb-2 text-3xs uppercase tracking-5 text-[var(--color-fg-disabled)]">
                    Observed room bindings
                  </div>
                  ${gate.bindings.length === 0
                    ? html`<div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-4 text-xs text-[var(--color-fg-disabled)]">관찰된 room 바인딩 없음</div>`
                    : html`
                        <div class="space-y-2">
                          ${gate.bindings.slice(0, 6).map(binding => html`<${BindingRow} binding=${binding} />`)}
                        </div>
                      `}
                </div>

                <div>
                  <div class="mb-2 text-3xs uppercase tracking-5 text-[var(--color-fg-disabled)]">
                    Recent gate events
                  </div>
                  ${gate.recent_events.length === 0
                    ? html`<div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-4 text-xs text-[var(--color-fg-disabled)]">커넥터 이벤트 기록 없음</div>`
                    : html`
                        <div class="space-y-2">
                          ${gate.recent_events.slice(0, 8).map(event => html`<${EventRow} event=${event} />`)}
                        </div>
                      `}
                </div>
              </div>

              ${gate.channels.length === 0
                ? html`<div class="py-4 text-center text-xs text-[var(--color-fg-disabled)]">활성 커넥터 없음</div>`
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
      <div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-6 text-center text-xs text-[var(--color-fg-disabled)]">
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
    <div class="contain-content">
      <div class="mb-3 flex items-center justify-between gap-3">
        <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">${filterId ? CONNECTOR_DISPLAY_NAMES[filterId as KnownConnectorId] ?? '커넥터' : '커넥터'}</h3>
        ${filterId
          ? html`
              <div class="text-right text-3xs uppercase tracking-5 text-[var(--color-fg-disabled)]">
                <div>${d ? `success ${d.success_rate_pct}%` : `${visibleConnectors.length} connector${visibleConnectors.length !== 1 ? 's' : ''}`}</div>
                <div>${d ? `uptime ${formatUptime(d.uptime_seconds)}` : '게이트 메트릭 없음'}</div>
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
              class="mb-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)]/40 p-3"
              data-testid="connector-detail-panel"
            >
              <div class="mb-3 flex items-center justify-between gap-3 text-2xs">
                <span class="font-semibold text-[var(--color-fg-primary)]">${CONNECTOR_DISPLAY_NAMES[focusedConnectorId]}</span>
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
              badge=${html`<span>키퍼 ${snapshot.keepers.length}</span>`}
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

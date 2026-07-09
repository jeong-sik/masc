// Connector Status — Channel Gate per-channel diagnostics panel.
// Keeper-first layout: each directory keeper is a primary section; bindings nest under.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { ConnectionStatus } from './dashboard-shell'
import type { ComponentChildren } from 'preact'
import { post } from '../api/core'
import { DEFAULT_MASC_ORIGIN } from '../config/constants'
import {
  fetchGateConnectors,
  fetchGateKeepers,
  fetchGateStatus,
  type BindingInfo,
  type ChannelInfo,
  type ConnectorNames,
  type DiscordConfiguredBinding,
  type GateConnectorInfo,
  type GateConnectorsData,
  type GateEventInfo,
  type GateKeeperInfo,
  type GateStatusData,
} from '../api/gate'
import {
  KNOWN_CONNECTOR_IDS,
  IN_PROCESS_CONNECTOR_ENV,
  isInProcessConnector,
  CONNECTOR_DISPLAY_NAMES,
  sidecarCommands,
  connectorAccentStyle,
  channelIcon,
  type KnownConnectorId,
  type InProcessConnectorId,
} from './connector-constants'
// Back-compat re-export: connector vocabulary now lives in ./connector-constants.
export {
  KNOWN_CONNECTOR_IDS,
  IN_PROCESS_CONNECTOR_IDS,
  IN_PROCESS_CONNECTOR_ENV,
  isInProcessConnector,
  CONNECTOR_DISPLAY_NAMES,
  sidecarCommands,
  connectorAccentStyle,
  channelIcon,
} from './connector-constants'
export type { KnownConnectorId, InProcessConnectorId, SidecarCommands } from './connector-constants'
import {
  connectorStateLabel,
  connectorCardBorderClass,
  connectorStateTone,
  dotClassForLabel,
  connectorCardStateClass,
  connectorStatusPillClass,
  connectorStatusPillLabel,
} from './connector-state'
// Back-compat re-export: connector state mapping now lives in ./connector-state.
export { connectorStateLabel, connectorCardBorderClass } from './connector-state'
export type { ConnectorStateLabel } from './connector-state'
import { formatTimeAgoEn } from '../lib/format-time'
import { ErrorState } from './common/feedback-state'
import { ConnectorOverviewSkeleton } from './connector-overview-skeleton'
import { lastEvent } from '../sse'
import { KpiStripIsland, type KpiStripIslandData } from './kpi-strip-island'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { StatusChip } from './common/status-chip'
import { showToast } from './common/toast'
import { CopyableCode } from './common/copyable-code'
import { SetupGuideCard } from './setup-guide-card'
import { ConnectorOnboardingGrid } from './connector-onboarding'
import { SurfaceCard, surfaceCardClassName } from './common/card'
import { SidecarLogToggle, SidecarLogViewer } from './sidecar-log-viewer'
import { ConnectorConfigToggle, ConnectorConfigForm, openConnectorConfig } from './connector-config-form'
import { ConnectorReadinessRail, deriveRail, getRailInflight, withRailInflight } from './connector-readiness-rail'
import { StartupCheckBanner, markStartAttempt, clearStartAttempt } from './sidecar-startup-watch'
import { showConnectorActionError } from './connector-action-error'
import { QuickBindForm } from './connector-quick-bind'
import { ConnectorFlowSection } from './connector-flow'
import { ConnectorOverviewStrip } from './connector-overview-strip'
import { ConnectorKeeperMatrix, deriveMatrix } from './connector-keeper-matrix'
import { ConnectorPathsStrip } from './connector-paths-strip'
import { createManagedAsyncResource } from '../lib/async-state'
import { navigate, route } from '../router'
import { Tk } from './tk'
import { KeeperBadge } from './keeper-badge'

function MutedSpan({ children }: { children: unknown }) {
  return html`<span class="text-[var(--color-fg-disabled)]">${children}</span>`
}

function BoldLabel({ children }: { children: unknown }) {
  return html`<span class="font-medium">${children}</span>`
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

// Per-connector lifecycle hints. The three remaining external sidecars
// (imessage/slack/telegram) ship a run.sh wrapper — see
// sidecars/<id>-bot/run.sh. Discord runs in-process under
// Server_discord_in_process_gateway (RFC-0203 §Phase 3, PR #19393);
// no sidecar process, no lifecycle command panel — see
// {@link IN_PROCESS_CONNECTOR_IDS}.
// Source of truth: docs/CONNECTOR-CONFIG-SCHEMA.md.
// Connector vocabulary (KNOWN_CONNECTOR_IDS, display names, sidecar commands,
// accent styles, channel icons) lives in ./connector-constants and is imported
// at the top of this file; re-exported there for back-compat.

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
const connectorSearchQuery = signal('')
const configDrawerConnectorId = signal<KnownConnectorId | null>(null)
const configDrawerTab = signal<'connection' | 'config' | 'events'>('connection')

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
 * Case-insensitive substring match on `group.name` and the keeper's
 * resolved runtime label (agent_name when distinct from
 * name). Operators on a crowded connector can locate a keeper by
 * partial name or by its runtime agent.
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

const timeAgo = formatTimeAgoEn

function healthTone(health: string): { dot: string; badge: string; label: string } {
  switch (health) {
    case 'healthy':
      return {
        dot: 'var(--green)',
        badge: 'border border-[var(--ok-border)] bg-[var(--ok-10)] text-[var(--color-status-ok)]',
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
        badge: 'border border-[var(--err-border)] bg-[var(--bad-10)] text-[var(--bad-light)]',
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

function runtimeLabelForKeeper(keeper: GateKeeperInfo | null | undefined): string {
  const runtime = keeper?.agent_name?.trim()
  if (!runtime || runtime === keeper?.name) return ''
  return runtime
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
    gateway_state: '',
    status_source: '',
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
    source_health: {
      storage_paths: 'fallback',
      runtime_summary: 'fallback',
      binding_summary: 'fallback',
      names: 'fallback',
      observed_channel: 'missing',
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

type ConnectorSourceHealthKey = keyof GateConnectorInfo['source_health']

const CONNECTOR_SOURCE_HEALTH_ROWS: Array<{ key: ConnectorSourceHealthKey; label: string }> = [
  { key: 'storage_paths', label: 'storage paths' },
  { key: 'runtime_summary', label: 'runtime summary' },
  { key: 'binding_summary', label: 'binding summary' },
  { key: 'names', label: 'names' },
  { key: 'observed_channel', label: 'observed channel' },
]

function connectorSourceHealthClass(state: GateConnectorInfo['source_health'][ConnectorSourceHealthKey]): string {
  switch (state) {
    case 'present':
      return 'border-[var(--color-status-ok)] text-[var(--color-status-ok)]'
    case 'missing':
      return 'border-[var(--color-border-default)] text-[var(--color-fg-disabled)]'
    case 'fallback':
      return 'border-[var(--color-status-warn)] text-[var(--color-status-warn)]'
  }
}

function ConnectorSourceHealthStrip({ connector }: { connector: GateConnectorInfo | null }) {
  const sourceHealth = connector?.source_health
  return html`
    <div
      class="mt-2 flex flex-wrap items-center gap-1.5 text-3xs"
      data-testid="connector-source-health"
      aria-label="Connector source health"
    >
      <span class="uppercase tracking-4 text-[var(--color-fg-disabled)]">source health</span>
      ${CONNECTOR_SOURCE_HEALTH_ROWS.map(row => {
        const state = sourceHealth?.[row.key] ?? 'missing'
        return html`
          <span
            key=${row.key}
            class=${`rounded-[var(--r-0)] border px-1.5 py-0.5 ${connectorSourceHealthClass(state)}`}
            data-connector-source-health=${row.key}
            data-connector-source-health-state=${state}
          >${row.label} ${state}</span>
        `
      })}
    </div>
  `
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
    showConnectorActionError(`${connectorId} sidecar 시작 실패`, err)
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
    showConnectorActionError(`${connectorId} sidecar 중지 실패`, err)
  } finally {
    patchConnectorUiState(connectorId, { actionLoading: false })
  }
}

/** Returns true only when the bind POST succeeded. Errors are surfaced
    here (toast + 상세 dialog) and swallowed, so this promise never
    rejects — callers must branch on the boolean, not try/catch. */
export async function bindConnector(connectorId: string, keeperName: string, channelId: string): Promise<boolean> {
  const keeper = keeperName.trim()
  const channel = channelId.trim()
  if (!keeper || !channel) return false

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
    return true
  } catch (err) {
    showConnectorActionError(`바인딩 실패: ${channel} → ${keeper}`, err)
    return false
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
    showConnectorActionError(`바인딩 해제 실패: ${channel}`, err)
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

const EMPTY_CONFIGURED_BINDINGS: DiscordConfiguredBinding[] = []

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
  const configuredBindings = connector?.configured_bindings ?? EMPTY_CONFIGURED_BINDINGS
  const names = connector?.names
  const connectorName = connector?.display_name || 'Connector'
  const connectorId = connector?.connector_id ?? ''
  const ui = getConnectorUiState(connectorId)
  const isActionLoading = ui.actionLoading
  const bindingActionsEnabled = connector != null && connector.capabilities.includes('bindings')
  const directLabel = connectorStateLabel(connector)
  const directTone = connectorStateTone(connector)
  // In-process gateway machine state (RFC-0203 / #20813). Shown only
  // when the connector advertises it AND it adds information beyond
  // the coarse 4-word label (reconnect_pending, identifying, failed...).
  const gatewayState = connector?.gateway_state ?? ''
  const showGatewayChip = gatewayState !== '' && gatewayState !== directLabel

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

  // observedWorkspaces / bindingsByKeeper / knownNames / knownGroups form a
  // derivation chain over stable props (gate, connector, configuredBindings,
  // keepers). The panel re-renders on unrelated UI state (keeperQuery filter
  // keystrokes, actionLoading toggles); memoizing each stage on its stable
  // upstream skips the workspace dedup + per-keeper binding regroup on those.
  const observedWorkspaces = useMemo(
    () => uniqueStrings([
      ...(gate?.bindings ?? [])
        .filter(binding => binding.channel === (connector?.channel ?? ''))
        .map(binding => binding.workspace_id),
      ...(gate?.recent_events ?? [])
        .filter(event => event.channel === (connector?.channel ?? ''))
        .map(event => event.workspace_id),
      ...configuredBindings.map(binding => binding.channel_id),
    ]),
    [gate, connector, configuredBindings],
  )

  const bindingsByKeeper = useMemo(() => {
    const m = new Map<string, Array<{ channel_id: string; keeper_name: string }>>()
    for (const binding of configuredBindings) {
      const existing = m.get(binding.keeper_name)
      if (existing) {
        existing.push(binding)
      } else {
        m.set(binding.keeper_name, [binding])
      }
    }
    return m
  }, [configuredBindings])
  const knownNames = useMemo(() => new Set(keepers.map(keeper => keeper.name)), [keepers])
  const knownGroups = useMemo<KeeperGroup[]>(() => keepers.map(keeper => ({
    name: keeper.name,
    keeper,
    bindings: bindingsByKeeper.get(keeper.name) ?? [],
    unknown: false,
  })), [keepers, bindingsByKeeper])
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
    hint: connectorError ? `${connector?.gate_base_url || DEFAULT_MASC_ORIGIN} 에서 서버 확인` : '',
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
  // RFC-0203 §Phase 3: in-process connectors (currently just Discord)
  // have no sidecar process and therefore no "사이드카 미시작" Start
  // affordance. Render the in-process info hint instead — see
  // showInProcessUnavailableHint below.
  const showSidecarOffEmpty =
    !showNoKeeperEmpty
    && configuredBindings.length === 0
    && !connector?.available
    && !isInProcessConnector(connectorId)
  const showInProcessUnavailableHint =
    !showNoKeeperEmpty
    && !connector?.available
    && isInProcessConnector(connectorId)

  const headerIcon = channelIcon(connector?.channel ?? connectorId)

  return html`
    <${SurfaceCard} id=${`connector-card-${connectorId}`} class="mb-4 scroll-mt-4 ${connectorCardBorderClass(directLabel)} !p-4" data-connector-card-state=${directLabel} style=${connectorAccentStyle(connectorId)}>
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
        ${showGatewayChip
          ? html`<span class="text-3xs lowercase text-[var(--color-fg-disabled)]" data-gateway-state-chip>gw ${gatewayState}</span>`
          : null}
        <${MutedSpan}><span aria-hidden="true">· </span>hb ${timeAgo(connector?.updated_at ?? '')}</${MutedSpan}>
        ${connector?.reply_mode
          ? html`<${MutedSpan}><span aria-hidden="true">· </span>reply ${connector.reply_mode}</${MutedSpan}>`
          : null}
        ${connector?.self_chat_guid
          ? html`<${MutedSpan}><span aria-hidden="true">· </span>self-chat ${truncateMiddle(connector.self_chat_guid, 28)}</${MutedSpan}>`
          : null}
        <span class="ml-auto flex items-center gap-2">
          ${connector?.available && !isInProcessConnector(connectorId)
            ? html`
                <button
                  type="button"
                  class="cursor-pointer rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--bad-10)] px-2 py-0.5 text-3xs uppercase tracking-4 text-[var(--bad-light)] hover:bg-[var(--bad-10)] disabled:opacity-50"
                  disabled=${isActionLoading}
                  aria-label=${`stop ${connectorName} sidecar`}
                  onClick=${() => { void stopSidecar(connectorId) }}
                >${isActionLoading ? '…' : 'Stop'}</button>
              `
            : null}
          ${!isInProcessConnector(connectorId)
            ? html`<${SidecarLogToggle} connectorId=${connectorId} />`
            : null}
          <${ConnectorConfigToggle} connectorId=${connectorId} />
          ${sidecarLogPath && !isInProcessConnector(connectorId)
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
              // RFC-0203 §Phase 3: in-process gateways have no
              // sidecar process to toggle. The readiness rail still
              // gets a callback to keep the type stable, but it's a
              // no-op for these connectors — the operator manages
              // them via env var + server restart.
              if (isInProcessConnector(connectorId)) return
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
      <${ConnectorSourceHealthStrip} connector=${connector} />

      <${StartupCheckBanner} connectorId=${connectorId} sidecarUp=${connector?.available === true} />

      ${connector?.available === true && keepers.length > 0
        ? html`<${QuickBindForm} connectorId=${connectorId} keepers=${keepers} />`
        : null}

      <${ConnectorFlowSection} connector=${connector} gate=${gate} />

      ${ui.headerExpanded
        ? html`
            <${SurfaceCard} class="mt-2 !bg-[var(--color-bg-elevated)] !p-3 text-2xs">
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
              </${SurfaceCard}>
              <div class="mt-3">
                <${ActionButton} variant="ghost" size="sm" disabled=${loading || isActionLoading} onClick=${() => { void refresh() }}>새로고침<//>
              </div>
            </div>
          `
        : null}

      ${connectorError || connector?.error
        ? html`
            <${SurfaceCard} class="mt-3 !border-[var(--warn-20)] !bg-[var(--warn-10)] !px-3 !py-2 text-2xs text-[var(--color-status-warn)]" data-connector-warning-panel>
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
            </${SurfaceCard}>
          `
        : null}

      ${!isInProcessConnector(connectorId)
        ? html`<${SidecarLogViewer} connectorId=${connectorId} />`
        : null}
      <${ConnectorConfigForm} connectorId=${connectorId} />

      ${keeperDirectoryError && keepers.length === 0
        ? html`
            <${SurfaceCard}
              class="mt-3 !border-[var(--warn-20)] !border-l-4 !border-l-[var(--color-warn)] !bg-[var(--warn-10)] !px-3 !py-2 text-2xs text-[var(--color-status-warn)]"
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
            </${SurfaceCard}>
          `
        : null}

      ${showNoKeeperEmpty
        ? html`
            <${SurfaceCard}
              class="mt-3 !border-dashed !border-[var(--warn-20)] !border-l-4 !border-l-[var(--color-warn)] !bg-[var(--warn-10)] !px-3 !py-3 text-xs"
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
            </${SurfaceCard}>
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
              <${SurfaceCard}
                class="mt-3 !border-dashed !border-[var(--warn-20)] !border-l-4 !border-l-[var(--color-warn)] !bg-[var(--warn-10)] !px-3 !py-3 text-xs"
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
              </${SurfaceCard}>
            `
          })()
        : null}

      ${showInProcessUnavailableHint
        ? (() => {
            // RFC-0203 §Phase 3: in-process gateways (Discord) have no
            // sidecar process to start, so the operator sees this hint
            // instead of the "Start sidecar" panel. Same amber tone as
            // the sidecar panel — "needs action, not broken" — but the
            // remediation is an env var + restart, not a CLI command.
            const envVar = IN_PROCESS_CONNECTOR_ENV[connectorId as InProcessConnectorId]
            return html`
              <${SurfaceCard}
                class="mt-3 !border-dashed !border-[var(--warn-20)] !border-l-4 !border-l-[var(--color-warn)] !bg-[var(--warn-10)] !px-3 !py-3 text-xs"
                data-in-process-not-running-panel
              >
                <div class="mb-1 flex flex-wrap items-center gap-2">
                  <span
                    class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--color-status-warn)]"
                    aria-label=${`${connectorName} in-process gateway 상태: 연결되지 않음`}
                    data-in-process-status-chip
                  >
                    <span aria-hidden="true">⊘</span>
                    <span>연결되지 않음</span>
                  </span>
                  <span class="font-medium text-[var(--color-fg-primary)]">서버 내장 게이트웨이</span>
                  ${connector?.updated_at
                    ? html`<span class="text-3xs text-[var(--color-fg-disabled)]">last seen ${timeAgo(connector.updated_at)}</span>`
                    : null}
                </div>
                <div class="text-2xs text-[var(--color-status-warn)]/80">
                  ${connectorName} 게이트웨이가 서버 프로세스 내부에서 동작합니다. 별도 사이드카 프로세스가 없으므로 Start/Stop 버튼이 없습니다. <${Tk}>${envVar}<//> 환경변수를 설정하고 서버를 재기동하면 자동으로 Discord Gateway 에 연결됩니다.
                </div>
                <${SetupGuideCard} connectorId=${connectorId} />
              </${SurfaceCard}>
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
                  placeholder="keeper / runtime 필터"
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
                  <${SurfaceCard} class="!bg-[var(--color-bg-elevated)] !px-3 !py-2" data-keeper=${group.name}>
                    <div class="flex flex-wrap items-baseline gap-3">
                      <div class="text-sm font-medium text-[var(--color-fg-primary)]">${group.name}</div>
                      ${keeper
                        ? html`
                            <div class="text-3xs text-[var(--color-fg-disabled)]">
                              status ${keeper.status || 'unknown'}
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
                            <${ActionButton}
                              variant="subtle"
                              size="sm"
                              ariaLabel=${`add channel to ${group.name}`}
                              onClick=${toggleExpand}
                            >${expanded ? '− 닫기' : '+ 채널 연결'}<//>
                          </div>
                          ${expanded
                            ? html`
                                <${SurfaceCard} class="mt-2 !border-dashed !border-[var(--color-border-default)] !bg-[var(--color-bg-surface)] !p-2">
                                  <${TextInput}
                                    value=${ui.channelDraft}
                                    placeholder=${`Paste ${connectorName} channel ID — right-click a channel → Copy ID`}
                                    ariaLabel=${`${connectorName} channel id`}
                                    onInput=${(e: Event) => { patchConnectorUiState(connectorId, { channelDraft: (e.target as HTMLInputElement).value }) }}
                                  />
                                  ${ui.channelDraft.trim() && humanizeChannel(names, ui.channelDraft.trim())
                                    ? html`<div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">resolves to ${humanizeChannel(names, ui.channelDraft.trim())}</div>`
                                    : null}
                                  ${observedWorkspaces.length > 0
                                    ? html`
                                        <div class="mt-2 flex flex-wrap gap-1.5">
                                          ${observedWorkspaces.slice(0, 8).map(workspaceId => {
                                            const humanized = humanizeChannel(names, workspaceId)
                                            return html`
                                              <${ActionButton}
                                                variant="ghost"
                                                size="sm"
                                                class="!rounded-[var(--r-0)] !py-0.5"
                                                title=${workspaceId}
                                                ariaLabel=${humanized ? `select ${humanized}` : `select ${truncateMiddle(workspaceId, 22)}`}
                                                onClick=${() => { patchConnectorUiState(connectorId, { channelDraft: workspaceId }) }}
                                              >${humanized
                                                ? html`<span>${humanized}</span><span class="ml-1 text-[var(--color-fg-disabled)]"><span aria-hidden="true">· </span>${truncateMiddle(workspaceId, 10)}</span>`
                                                : truncateMiddle(workspaceId, 22)}<//>
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
                                </${SurfaceCard}>
                              `
                            : null}
                        `
                      : null}
                  </${SurfaceCard}>
                `
              })}
            </div>
          `
        : null}

      ${unknownGroups.length > 0
        ? html`
            <div class="mt-3 space-y-2">
              ${unknownGroups.map(group => html`
                <${SurfaceCard} class="!border-[var(--warn-20)] !bg-[var(--warn-10)] !px-3 !py-2" data-keeper=${group.name}>
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
                </${SurfaceCard}>
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
    </${SurfaceCard}>
  `
}

function ChannelCard({ ch }: { ch: ChannelInfo }) {
  const tone = healthTone(ch.health)
  const lastError = shortText(ch.last_error)

  return html`
    <${SurfaceCard} class="!bg-[var(--color-bg-elevated)] !p-3">
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

      <div class="grid grid-cols-2 gap-2 text-xs md:grid-cols-3">
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
          <div class="font-mono text-[var(--color-fg-primary)]">${ch.workspace_count}</div>
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
          <span class="font-mono text-[var(--color-fg-primary)]"> ${ch.last_workspace_id || '-'}</span>
        </div>
      </div>

      ${lastError
        ? html`
            <${SurfaceCard} class="mt-3 !border-[var(--err-border)] !bg-[var(--bad-10)] !px-3 !py-2 text-2xs text-[var(--bad-light)]">
              <div class="mb-1 uppercase tracking-5 text-[var(--bad-light)]/80">
                ${ch.last_error_kind || 'error'} · ${timeAgo(ch.last_error_at)}
              </div>
              <div>${lastError}</div>
            </${SurfaceCard}>
          `
        : null}
    </${SurfaceCard}>
  `
}

function BindingRow({ binding }: { binding: BindingInfo }) {
  const tone = healthTone(binding.health)
  const lastError = shortText(binding.last_error, 72)

  return html`
    <${SurfaceCard} class="!bg-[var(--color-bg-elevated)] !px-3 !py-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-xs font-medium text-[var(--color-fg-primary)]">
            ${binding.channel} · workspace ${truncateMiddle(binding.workspace_id)}
          </div>
          <div class="text-3xs uppercase tracking-5 text-[var(--color-fg-disabled)]">
            ${binding.keeper ? `keeper ${binding.keeper}` : 'keeper pending'}
          </div>
        </div>
        <span class=${`rounded-[var(--r-0)] px-2 py-1 text-3xs uppercase tracking-5 ${tone.badge}`}>
          ${tone.label}
        </span>
      </div>
      <div class="mt-2 grid grid-cols-1 gap-2 text-2xs text-[var(--color-fg-disabled)] sm:grid-cols-3">
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
            <${SurfaceCard} class="mt-2 !border-[var(--err-border)] !bg-[var(--bad-10)] !px-2 !py-1 text-3xs text-[var(--bad-light)]">
              ${binding.last_error_kind || 'error'} · ${lastError}
            </${SurfaceCard}>
          `
        : null}
    <//>
  `
}

function EventRow({ event }: { event: GateEventInfo }) {
  const isError = Boolean(event.error)
  const badgeClass = isError
    ? 'border border-[var(--err-border)] bg-[var(--bad-10)] text-[var(--bad-light)]'
    : 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)]'

  return html`
    <${SurfaceCard} class="!bg-[var(--color-bg-elevated)] !px-3 !py-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 text-2xs text-[var(--color-fg-disabled)]">
          <div class="font-medium text-[var(--color-fg-primary)]">
            ${event.channel} · ${event.keeper || 'unassigned'} · workspace ${truncateMiddle(event.workspace_id)}
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
    <details class="group mb-4 ${surfaceCardClassName({ variant: 'standard' })} !p-0" data-testid=${testId}>
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
            <${SurfaceCard} class="!border-dashed !border-[var(--color-border-default)] !px-3 !py-4 text-xs text-[var(--color-fg-disabled)]">
              connector runtime은 등록됐으나 게이트가 관찰한 트래픽은 아직 없습니다.
            </${SurfaceCard}>
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
                <${SurfaceCard} class="!bg-[var(--color-bg-elevated)] !px-3 !py-2">duplicate suppressions
                  <span class="ml-2 font-mono text-[var(--color-fg-primary)]">${gate.total_duplicates}</span>
                <//>
                <${SurfaceCard} class="!bg-[var(--color-bg-elevated)] !px-3 !py-2">active connectors
                  <span class="ml-2 font-mono text-[var(--color-fg-primary)]">${gate.channels.length}</span>
                <//>
              </div>

              <div class="mb-4 grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
                <div>
                  <div class="mb-2 text-3xs uppercase tracking-5 text-[var(--color-fg-disabled)]">
                    Observed workspace bindings
                  </div>
                  ${gate.bindings.length === 0
                    ? html`<${SurfaceCard} class="!border-dashed !border-[var(--color-border-default)] !px-3 !py-4 text-xs text-[var(--color-fg-disabled)]">관찰된 workspace 바인딩 없음</${SurfaceCard}>`
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
                    ? html`<${SurfaceCard} class="!border-dashed !border-[var(--color-border-default)] !px-3 !py-4 text-xs text-[var(--color-fg-disabled)]">커넥터 이벤트 기록 없음</${SurfaceCard}>`
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

function formatConnectorTimestamp(iso: string | null | undefined): string {
  if (!iso) return '-'
  const ts = Date.parse(iso)
  return Number.isNaN(ts) ? iso : new Date(ts).toLocaleString()
}

function ConnectorsSurfaceHeader({
  filterId,
  connectorCount,
  activeCount,
  onRefresh,
}: {
  filterId: KnownConnectorId | null
  connectorCount: number
  activeCount: number
  onRefresh: () => void
}) {
  return html`
    <header class="cn-surf-head surf-head">
      <div>
        <div class="eyebrow">Gate</div>
        <h1>${filterId ? CONNECTOR_DISPLAY_NAMES[filterId] ?? '커넥터' : '커넥터'}</h1>
        <div class="cn-surf-sub surf-sub">
          외부 게이트 ${connectorCount}개 · <b>${activeCount} active</b> ·
          <span class="mono">GET /api/v1/gate/connectors</span>
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-testid="connector-reality-notice">
          <${StatusChip} tone="info" uppercase=${false}>혼합 연결<//>
          <span>Discord는 서버 내장 gateway, iMessage/Slack/Telegram은 sidecar 관측 기반입니다.</span>
        </div>
      </div>
      <div class="cn-surf-actions" style=${{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <${ConnectionStatus} />
        <button
          type="button"
          class="cn-act act"
          aria-label="게이트 설정 열기"
          onClick=${() => { navigate('settings') }}
        >게이트 설정 →</button>
        <button
          type="button"
          class="cn-act act"
          aria-label="게이트 새로고침"
          onClick=${onRefresh}
        >게이트 새로고침 ↻</button>
      </div>
    </header>
  `
}

function ConnectorRouteSwitcher({ activeConnectorId }: { activeConnectorId: KnownConnectorId | null }) {
  return html`
    <div class="cn-route-switcher" data-testid="connector-route-switcher" role="group" aria-label="Connector route scope">
      <button
        type="button"
        class=${`cn-route-chip ${activeConnectorId === null ? 'on' : ''}`}
        data-testid="connector-route-all"
        data-active=${activeConnectorId === null ? 'true' : 'false'}
        onClick=${() => { navigate('connectors', { section: 'connector-status' }) }}
      >
        <span class="cn-route-ico" aria-hidden="true">∷</span>
        <span>All</span>
      </button>
      ${KNOWN_CONNECTOR_IDS.map(connectorId => html`
        <button
          type="button"
          key=${connectorId}
          class=${`cn-route-chip ${activeConnectorId === connectorId ? 'on' : ''}`}
          data-testid=${`connector-route-${connectorId}`}
          data-active=${activeConnectorId === connectorId ? 'true' : 'false'}
          onClick=${() => { navigate('connectors', { section: 'connector-status', connector: connectorId }) }}
        >
          <span class="cn-route-ico" aria-hidden="true">${channelIcon(connectorId)}</span>
          <span>${CONNECTOR_DISPLAY_NAMES[connectorId]}</span>
        </button>
      `)}
    </div>
  `
}

function ConnectorsToolbar({
  query,
  onQuery,
}: {
  query: string
  onQuery: (value: string) => void
}) {
  return html`
    <div class="cn-toolbar">
      <${TextInput}
        type="search"
        value=${query}
        placeholder="Filter connectors by name, channel, or status"
        ariaLabel="커넥터 필터"
        testId="connector-search-input"
        class="cn-search"
        onInput=${(e: Event) => { onQuery((e.target as HTMLInputElement).value) }}
      />
    </div>
  `
}

function GateStatusStrip({
  gate,
  connectors,
}: {
  gate: GateStatusData | null
  connectors: GateConnectorInfo[]
}) {
  const healthy = gate !== null && connectors.some(c => c.gate_healthy === true)
  // Prototype gate-strip dot is <StatusDot status pulse/> → window.KV.Dot → `.dot2`
  // (messages.jsx:8 maps run→ok, pause→warn, off→idle). The vendored CSS styles
  // `.dot2` / `.dot2.ok` / `.dot2.warn` (v2.css:395); there is no `.status-dot`
  // rule, so emit the prototype's `.dot2` vocabulary instead.
  function statusDotClass(): string {
    if (healthy) return 'dot2 ok pulse'
    if (gate === null) return 'dot2'
    return 'dot2 warn'
  }
  function statusLabel(): string {
    if (healthy) return 'healthy'
    if (gate === null) return 'unknown'
    return 'degraded'
  }
  function resolveGeneratedAt(): string {
    if (connectors[0]?.updated_at) return formatConnectorTimestamp(connectors[0].updated_at)
    if (gate?.recent_events?.[0]?.timestamp) return formatConnectorTimestamp(gate.recent_events[0].timestamp)
    return '-'
  }
  const generatedAt = resolveGeneratedAt()

  return html`
    <div class="cn-gate-strip gate-strip" data-testid="connector-gate-strip">
      <span>
        <span class=${statusDotClass()}></span>
        gate <b>${statusLabel()}</b>
      </span>
      <span class="sep"></span>
      <span class="mono">base ${connectors[0]?.gate_base_url || DEFAULT_MASC_ORIGIN}</span>
      <span class="sep"></span>
      <span>
        health check <b class="mono">${gate?.recent_events?.[0]?.timestamp
          ? timeAgo(gate.recent_events[0].timestamp)
          : 'pending'}</b>
      </span>
      <span class="sep"></span>
      <span>binding source <b>${connectors[0]?.binding_source || 'store + runtime'}</b></span>
      <span style=${{ marginLeft: 'auto' }} class="mono">generated_at ${generatedAt}</span>
    </div>
  `
}

function connectorDisplayValue(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return '-'
  return String(value)
}

function ConnectorValueCell({
  label,
  value,
  highlight,
}: {
  label: string
  value: string | number | null | undefined
  highlight?: boolean
}) {
  return html`
    <div class="cell">
      <div class="k">${label}</div>
      <div class=${`v ${highlight ? 'hl' : ''}`}>${connectorDisplayValue(value)}</div>
    </div>
  `
}

function ConnectorBindingKeeperLink({ binding }: { binding: DiscordConfiguredBinding }) {
  // keeper_name is a required non-null field on DiscordConfiguredBinding (valibot
  // string()), so no optional chaining; the empty-string guard below stays since
  // string() still permits ''.
  const keeperName = binding.keeper_name.trim()
  if (!keeperName) {
    return html`
      <div class="cn-bind-row" data-binding-channel=${binding.channel_id}>
        <span class="chn">${binding.channel_id}</span>
        <span class="arr">→</span>
        <span class="text-[var(--text-bright)]">-</span>
      </div>
    `
  }

  return html`
    <button
      type="button"
      class="cn-bind-row link"
      data-testid="connector-binding-keeper-link"
      data-binding-channel=${binding.channel_id}
      data-binding-keeper=${keeperName}
      title=${`${keeperName} keeper 대화 열기`}
      aria-label=${`${binding.channel_id} binding keeper ${keeperName} 열기`}
      onClick=${() => { navigate('keepers', { keeper: keeperName }) }}
    >
      <span class="chn">${binding.channel_id}</span>
      <span class="arr">→</span>
      <span class="text-[var(--text-bright)]">
        <${KeeperBadge} id=${keeperName} variant="full" size="sm" />
      </span>
      <span class="cn-bind-go" aria-hidden="true">▸</span>
    </button>
  `
}

function ConnectorGateCard({
  connectorId,
  connector,
  onOpenConfig,
}: {
  connectorId: KnownConnectorId
  connector: GateConnectorInfo | null
  onOpenConfig: (connectorId: KnownConnectorId) => void
}) {
  const displayName = connector?.display_name || CONNECTOR_DISPLAY_NAMES[connectorId] || connectorId
  const label = connectorStateLabel(connector)
  const pillClass = connectorStatusPillClass(label)
  const bindings = connector?.configured_bindings ?? EMPTY_CONFIGURED_BINDINGS
  const caps = connector?.capabilities?.length ? connector.capabilities : ['bindings']
  // Prototype card cell label is exactly `Base URL` (webhook) or `Guilds`
  // (connectors.jsx:96); value is the base URL or the numeric guild count.
  // Mirror the existing connectorScopeLabel/connectorScopeValue helpers
  // (below) so the card and the live panel agree on the same wiring.
  const scopeLabel = connectorScopeLabel(connector)
  const scopeValue = connectorScopeValue(connector)

  return html`
    <article
      class=${`cn-card ${connectorCardStateClass(label)}`}
      data-testid="connector-gate-card"
      data-connector-card=${connectorId}
      data-connector-card-state=${label}
    >
      <div class="cn-h">
        <span class="cn-glyph" aria-hidden="true">${channelIcon(connector?.channel ?? connectorId)}</span>
        <div class="meta">
          <div class="nm">${displayName}</div>
          <div class="ch">${connectorId} · channel: ${connector?.channel ?? connectorId}</div>
        </div>
        <span class=${`cn-status-pill ${pillClass}`}>
          <span class="dot"></span>
          ${connectorStatusPillLabel(label)}
        </span>
        <button
          type="button"
          class="cn-config"
          aria-label=${`${displayName} 설정 열기`}
          title="이 게이트 상세 설정"
          onClick=${() => { onOpenConfig(connectorId) }}
        >⚙</button>
      </div>

      <div class="cn-kv">
        <${ConnectorValueCell} label="Bot" value=${connector?.bot_user_name || connector?.bot_user_id} highlight />
        <${ConnectorValueCell} label="Reply mode" value=${connector?.reply_mode || 'manual'} />
        <${ConnectorValueCell} label=${scopeLabel} value=${scopeValue} />
        <${ConnectorValueCell} label="PID" value=${connector?.pid || '-'} />
        <${ConnectorValueCell} label="Last ready" value=${connector?.last_ready_at ? timeAgo(connector.last_ready_at) : '-'} />
        <${ConnectorValueCell} label="Updated" value=${connector?.updated_at ? timeAgo(connector.updated_at) : '-'} />
      </div>

      <div class="cn-caps">
        ${caps.slice(0, 6).map(cap => html`<span class="cn-cap">${cap}</span>`)}
      </div>

      <div class="cn-bind">
        <h5>바인딩 — 채널 → keeper (${bindings.length})</h5>
        ${bindings.length
          ? bindings.map(binding => html`
              <${ConnectorBindingKeeperLink} key=${binding.channel_id} binding=${binding} />
            `)
          : html`<div class="cn-bind-none">바인딩 없음 — 이 게이트는 알림 전용입니다.</div>`}
        ${connector?.error
          ? html`<div class="callout mt-2"><span class="ico">⚠</span><span>${connector.error}</span></div>`
          : null}
      </div>
    </article>
  `
}

function ConnectorsGateGrid({
  connectors,
  filterQuery,
  onOpenConfig,
}: {
  connectors: GateConnectorInfo[]
  filterQuery: string
  onOpenConfig: (connectorId: KnownConnectorId) => void
}) {
  const query = filterQuery.trim().toLowerCase()
  const cards = KNOWN_CONNECTOR_IDS
    .map(connectorId => ({
      connectorId,
      connector: findKnownConnector(connectors, connectorId) ?? placeholderConnector(connectorId),
    }))
    .filter(({ connectorId, connector }) => {
      if (!query) return true
      const haystack = [
        connectorId,
        CONNECTOR_DISPLAY_NAMES[connectorId],
        connector.display_name,
        connector.channel,
        connectorStateLabel(connector),
        connector.bot_user_name,
      ].join(' ').toLowerCase()
      return haystack.includes(query)
    })

  return html`
    <div class="cn-grid" data-testid="connector-gate-grid">
      ${cards.map(({ connectorId, connector }) => html`
        <${ConnectorGateCard}
          connectorId=${connectorId}
          connector=${connector}
          onOpenConfig=${onOpenConfig}
        />
      `)}
    </div>
  `
}

function ConnectorsAuditLog({ connectors }: { connectors: GateConnectorInfo[] }) {
  const rows = connectors
    .flatMap(connector => (connector.recent_audit ?? []).map(audit => ({
      connector,
      audit,
    })))
    .sort((a, b) => Date.parse(b.audit.timestamp) - Date.parse(a.audit.timestamp))
    .slice(0, 5)

  return html`
    <section class="cn-audit" data-testid="connector-audit-log">
      <div class="cn-audit-h ov-card-h">
        <h3>최근 감사 로그</h3>
        <span class="cn-audit-legend ov-legend mono">recent_audit · last 5</span>
      </div>
      ${rows.length
        ? html`
            <table>
              <thead>
                <tr>
                  <th>시각</th>
                  <th>액션</th>
                  <th>대상</th>
                  <th>Keeper</th>
                  <th>Actor</th>
                  <th>이전 keeper</th>
                </tr>
              </thead>
              <tbody>
                ${rows.map(({ connector, audit }) => html`
                  <tr>
                    <td>${formatConnectorTimestamp(audit.timestamp)}</td>
                    <td class="act">${audit.action}</td>
                    <td>${audit.channel_id || connector.connector_id}</td>
                    <td>${audit.keeper_name || '-'}</td>
                    <td>${audit.actor_name || audit.actor_id || '-'}</td>
                    <td>${audit.previous_keeper || '-'}</td>
                  </tr>
                `)}
              </tbody>
            </table>
          `
        : html`<div class="cn-bind-none">최근 감사 로그 없음</div>`}
    </section>
  `
}

function connectorScopeLabel(connector: GateConnectorInfo | null): string {
  return connector?.channel === 'webhook' ? 'Base URL' : 'Guilds'
}

function connectorScopeValue(connector: GateConnectorInfo | null): string {
  if (!connector) return '-'
  if (connector.channel === 'webhook') return connector.gate_base_url || '-'
  if (connector.guild_count > 0) return String(connector.guild_count)
  return connector.gate_base_url || '-'
}

function connectorBotValue(connector: GateConnectorInfo | null): string {
  return connector?.bot_user_name || connector?.bot_user_id || ''
}

function ConnectorReadOnlyRow({
  label,
  value,
  hint,
  testId,
}: {
  label: string
  value: ComponentChildren
  hint?: ComponentChildren
  testId?: string
}) {
  return html`
    <div class="cn-set-row" data-testid=${testId ?? null}>
      <div class="cn-set-row-l">
        <div class="cn-set-label">${label}</div>
        ${hint ? html`<div class="cn-set-hint">${hint}</div>` : null}
      </div>
      <div class="cn-set-row-c">${value}</div>
    </div>
  `
}

function ConnectorBindingSummary({ connector }: { connector: GateConnectorInfo | null }) {
  const bindings = connector?.configured_bindings ?? EMPTY_CONFIGURED_BINDINGS

  return html`
    <div class="cn-drawer-section" data-testid="connector-binding-summary">
      <h4>채널 → keeper 바인딩 (${bindings.length})</h4>
      <div class="cn-set-hint">
        ${connector?.binding_source || 'GET /api/v1/gate/connectors'} 기준의 현재 바인딩입니다.
      </div>
      ${bindings.length
        ? html`
            <div class="space-y-2">
              ${bindings.map(binding => html`
                <div data-testid="connector-binding-summary-row" data-drawer-binding=${binding.channel_id}>
                  <${ConnectorBindingKeeperLink} key=${binding.channel_id} binding=${binding} />
                </div>
              `)}
            </div>
          `
        : html`<div class="cn-bind-none">바인딩 없음 — 알림 전용 게이트</div>`}
    </div>
  `
}

function ConnectorDetailDrawer({
  connectorId,
  connector,
  onClose,
}: {
  connectorId: KnownConnectorId
  connector: GateConnectorInfo | null
  onClose: () => void
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  useEffect(() => {
    openConnectorConfig(connectorId)
  }, [connectorId])

  return html`
    <${ConnectorDetailDrawerBody}
      key=${connectorId}
      connectorId=${connectorId}
      connector=${connector}
      onClose=${onClose}
    />
  `
}

function ConnectorDetailDrawerBody({
  connectorId,
  connector,
  onClose,
}: {
  connectorId: KnownConnectorId
  connector: GateConnectorInfo | null
  onClose: () => void
}) {
  const displayName = CONNECTOR_DISPLAY_NAMES[connectorId] ?? connectorId
  const tab = configDrawerTab.value
  const auditRows = connector?.recent_audit ?? []

  return html`
    <div class="cn-drawer-overlay" onClick=${onClose} data-testid="connector-detail-drawer">
      <div class="cn-drawer" onClick=${(e: Event) => { e.stopPropagation() }}>
        <div class="cn-drawer-hd">
          <div>
            <h3>${channelIcon(connector?.channel ?? connectorId)} ${displayName} 상태 및 설정</h3>
            <span class="id">${connectorId}</span>
          </div>
          <button
            type="button"
            class="cn-drawer-close"
            aria-label="닫기 (Esc)"
            onClick=${onClose}
          >✕</button>
        </div>
        <div class="cn-drawer-tabs">
          ${(['connection', 'config', 'events'] as const).map(t => html`
            <button
              type="button"
              class=${`cn-drawer-tab ${tab === t ? 'on' : ''}`}
              onClick=${() => { configDrawerTab.value = t }}
            >${t}</button>
          `)}
        </div>
        <div class="cn-drawer-body">
          ${tab === 'connection' && html`
            <div class="cn-drawer-section" data-testid="connector-live-settings-summary">
              <h4>연결 상태</h4>
              <${ConnectorReadOnlyRow}
                label="게이트 상태"
                value=${html`<span class=${`cn-status-pill ${connectorStatusPillClass(connectorStateLabel(connector))}`}><span class="dot"></span>${connectorStatusPillLabel(connectorStateLabel(connector))}</span>`}
                hint=${html`
                  status ${connectorStateLabel(connector)}
                  ${connector?.gate_healthy !== null
                    ? html` · gate ${connector?.gate_healthy ? 'healthy' : 'unhealthy'}`
                    : null}
                  ${connector?.updated_at ? html` · heartbeat ${timeAgo(connector.updated_at)}` : null}
                `}
                testId="connector-readonly-status-row"
              />
              <${ConnectorReadOnlyRow}
                label="Bot"
                value=${html`<span class="mono cn-set-static">${connectorBotValue(connector) || '-'}</span>`}
                testId="connector-readonly-bot-row"
              />
              <${ConnectorReadOnlyRow}
                label=${connectorScopeLabel(connector)}
                value=${html`<span class="mono cn-set-static">${connectorScopeValue(connector)}</span>`}
              />
              <${ConnectorReadOnlyRow}
                label="Reply mode"
                value=${html`<span class="mono cn-set-static">${connector?.reply_mode || 'manual'}</span>`}
                testId="connector-reply-mode-summary"
              />
              <${ConnectorReadOnlyRow}
                label="PID"
                value=${html`<span class="mono cn-set-static">${connector?.pid || '-'}</span>`}
              />
              ${connector?.error
                ? html`
                    <div class="mt-2 rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--bad-10)] px-2 py-1 text-2xs text-[var(--bad-light)]">
                      ⚠ ${connector.error}
                    </div>
                  `
                : null}
            </div>
            <${ConnectorBindingSummary} connector=${connector} />
          `}
          ${tab === 'config' && html`
            <div class="cn-drawer-section">
              <div class="mb-2 flex items-center justify-between">
                <h4>Config</h4>
              </div>
              <${ConnectorConfigForm} connectorId=${connectorId} />
            </div>
          `}
          ${tab === 'events' && html`
            <div class="cn-drawer-section">
              <h4>Event log</h4>
              ${auditRows.length
                ? html`
                    <table class="w-full border-collapse text-2xs">
                      <thead>
                        <tr class="text-left text-[var(--color-fg-disabled)]">
                          <th class="pb-1">시각</th>
                          <th class="pb-1">액션</th>
                          <th class="pb-1">Keeper</th>
                          <th class="pb-1">Actor</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${auditRows.map(a => html`
                          <tr class="border-t border-[var(--color-border-default)]">
                            <td class="py-1 font-mono text-[var(--color-fg-secondary)]">${formatConnectorTimestamp(a.timestamp)}</td>
                            <td class="py-1 text-[var(--color-fg-primary)]">${a.action}</td>
                            <td class="py-1 font-mono text-[var(--color-fg-secondary)]">${a.keeper_name}</td>
                            <td class="py-1 text-[var(--color-fg-secondary)]">${a.actor_name}</td>
                          </tr>
                        `)}
                      </tbody>
                    </table>
                  `
                : html`<div class="text-2xs text-[var(--color-fg-disabled)]">최근 감사 로그 없음</div>`}
            </div>
          `}
        </div>
      </div>
    </div>
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

  const connectorCount = filterId ? allConnectors.length : KNOWN_CONNECTOR_IDS.length
  const activeCount = allConnectors.filter(c => connectorStateLabel(c) === 'connected').length

  return html`
    <main class="v2-connector-status v2-connectors-surface surf" data-screen-label="커넥터">
      <div class="surf-scroll">
      <${ConnectorsSurfaceHeader}
        filterId=${filterId as KnownConnectorId | null}
        connectorCount=${connectorCount}
        activeCount=${activeCount}
        onRefresh=${() => { void refresh() }}
      />
      <${ConnectorRouteSwitcher} activeConnectorId=${filterId as KnownConnectorId | null} />

      ${!filterId
        ? html`
            <${GateStatusStrip} gate=${d} connectors=${allConnectors} />
            <${ConnectorsGateGrid}
              connectors=${allConnectors}
              filterQuery=${connectorSearchQuery.value}
              onOpenConfig=${(connectorId: KnownConnectorId) => {
                configDrawerConnectorId.value = connectorId
                configDrawerTab.value = 'connection'
              }}
            />
            <${ConnectorsAuditLog} connectors=${allConnectors} />
          `
        : null}

      ${!filterId
        ? html`
            <details class="v2-connectors-rollup" data-testid="connector-operations-rollup">
              <summary>
                <span>운영 상세</span>
                <span class="mono">readiness · live panel · paths · analytics</span>
              </summary>
              <div class="v2-connectors-rollup-body">
                <${ConnectorsToolbar}
                  query=${connectorSearchQuery.value}
                  onQuery=${(value: string) => { connectorSearchQuery.value = value }}
                />
                <${ConnectorOverviewStrip}
                  connectors=${allConnectors}
                  keeperCount=${snapshot.keepers.length}
                  discordTriggerPolicy=${snapshot.connectors?.discord_trigger_policy}
                  selectedConnectorId=${focusedConnectorId}
                  onSelectConnector=${(connectorId: KnownConnectorId) => { selectedConnectorId.value = connectorId }}
                  onOpenConfig=${(connectorId: KnownConnectorId) => {
                    configDrawerConnectorId.value = connectorId
                    configDrawerTab.value = 'connection'
                  }}
                  detailTargetId="connector-detail-panel"
                  filterQuery=${connectorSearchQuery.value}
                />
                <${SurfaceCard}
                  id="connector-detail-panel"
                  class="mb-4 !bg-[var(--color-bg-page)]/40 !p-3"
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
                </${SurfaceCard}>
                <${DisclosurePanel}
                  title="키퍼 매트릭스"
                  badge=${html`<span>키퍼 ${snapshot.keepers.length}</span>`}
                  testId="connector-matrix-disclosure"
                >
                  <${ConnectorKeeperMatrix} matrix=${deriveMatrix(allConnectors, snapshot.keepers)} />
                <//>
                <${ConnectorPathsStrip} connectors=${allConnectors} />
                <${GateAnalyticsSection} gate=${d} gateError=${snapshot.gateError} />
              </div>
            </details>
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

      ${filterId ? html`<${GateAnalyticsSection} gate=${d} gateError=${snapshot.gateError} />` : null}
      </div>

      ${configDrawerConnectorId.value
        ? html`
            <${ConnectorDetailDrawer}
              connectorId=${configDrawerConnectorId.value}
              connector=${findKnownConnector(allConnectors, configDrawerConnectorId.value)}
              onClose=${() => { configDrawerConnectorId.value = null }}
            />
          `
        : null}
    </main>
  `
}

export function resetConnectorStatusState() {
  connectorStatusResource.reset(EMPTY_SNAPSHOT)
  connectorUiState.value = {}
  selectedConnectorId.value = null
  connectorSearchQuery.value = ''
  configDrawerConnectorId.value = null
  configDrawerTab.value = 'connection'
}

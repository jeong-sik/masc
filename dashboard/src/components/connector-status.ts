// Connector Status — Channel Gate per-channel diagnostics panel.
// Keeper-first layout: each directory keeper is a primary section; bindings nest under.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
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
import { ErrorState, LoadingState } from './common/feedback-state'
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
import { ConnectorReadinessRail, deriveRail } from './connector-readiness-rail'
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
export interface SidecarCommands {
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

const actionLoading = signal(false)
const channelDraft = signal('')
const expandedKeeperFor = signal<string | null>(null)
const headerExpanded = signal(false)

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
        badge: 'border border-emerald-400/30 bg-emerald-500/12 text-emerald-100',
        label: 'healthy',
      }
    case 'degraded':
      return {
        dot: 'var(--yellow)',
        badge: 'border border-amber-400/30 bg-amber-500/12 text-amber-100',
        label: 'degraded',
      }
    case 'failing':
      return {
        dot: 'var(--red)',
        badge: 'border border-rose-400/35 bg-rose-500/12 text-rose-100',
        label: 'failing',
      }
    default:
      return {
        dot: 'var(--text-dim)',
        badge: 'border border-[var(--white-8)] bg-[var(--white-4)] text-[var(--text-dim)]',
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
      return 'bg-emerald-400'
    case 'warn':
      return 'bg-amber-400'
    case 'down':
      return 'bg-rose-400'
    default:
      return 'bg-[var(--text-dim)]'
  }
}

function dotClassForLabel(label: string): string {
  switch (label) {
    case 'connected':
      return 'bg-emerald-400'
    case 'stale':
      return 'bg-amber-400'
    case 'disconnected':
      return 'bg-rose-400'
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

function connectorStateLabel(connector: GateConnectorInfo | null): string {
  const advertised = connector?.status?.trim().toLowerCase()
  if (advertised === 'offline' || advertised === 'stale' || advertised === 'connected' || advertised === 'disconnected') {
    return advertised
  }
  if (!connector?.available) return 'offline'
  if (connector.stale) return 'stale'
  if (connector.connected) return 'connected'
  return 'disconnected'
}

function connectorStateTone(connector: GateConnectorInfo | null): string {
  const label = connectorStateLabel(connector)
  if (label === 'connected') {
    return 'border-emerald-400/30 bg-emerald-500/12 text-emerald-100'
  }
  if (label === 'disconnected') {
    return 'border-rose-400/30 bg-rose-500/12 text-rose-100'
  }
  return 'border-amber-400/30 bg-amber-500/12 text-amber-100'
}

// Native lifecycle hits the new /api/v1/sidecar/{start,stop} endpoints
// (see lib/server/server_routes_http_routes_sidecar.ml). The endpoints
// shell out to the same ./run.sh wrapper the operator would otherwise
// run by hand, so the dashboard button and the copy-paste command are
// behaviourally identical — only convenience differs.
export async function startSidecar(connectorId: string) {
  actionLoading.value = true
  try {
    await post(`/api/v1/sidecar/start?name=${encodeURIComponent(connectorId)}`, {})
    showToast(`${connectorId} sidecar 시작 요청 — 잠시 후 상태 갱신됩니다.`, 'success')
    await refresh()
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'start failed', 'error')
  } finally {
    actionLoading.value = false
  }
}

export async function stopSidecar(connectorId: string) {
  actionLoading.value = true
  try {
    await post(`/api/v1/sidecar/stop?name=${encodeURIComponent(connectorId)}`, {})
    showToast(`${connectorId} sidecar에 SIGTERM 전송`, 'success')
    await refresh()
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'stop failed', 'error')
  } finally {
    actionLoading.value = false
  }
}

async function bindConnector(connectorId: string, keeperName: string, channelId: string) {
  const keeper = keeperName.trim()
  const channel = channelId.trim()
  if (!keeper || !channel) return

  actionLoading.value = true
  try {
    await post(`/api/v1/gate/connector/bind?name=${encodeURIComponent(connectorId)}`, {
      channel_id: channel,
      keeper_name: keeper,
    })
    channelDraft.value = ''
    expandedKeeperFor.value = null
    await refresh()
    showToast(`Bound ${channel} -> ${keeper}`, 'success')
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'bind failed', 'error')
  } finally {
    actionLoading.value = false
  }
}

async function unbindConnector(connectorId: string, channelId: string) {
  const channel = channelId.trim()
  if (!channel) return

  actionLoading.value = true
  try {
    await post(`/api/v1/gate/connector/unbind?name=${encodeURIComponent(connectorId)}`, {
      channel_id: channel,
    })
    await refresh()
    showToast(`Unbound ${channel}`, 'success')
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'unbind failed', 'error')
  } finally {
    actionLoading.value = false
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
    <div class="mb-4 rounded-xl border border-[var(--white-8)] p-4" style=${connectorAccentStyle(connectorId)}>
      <div class="flex flex-wrap items-center gap-2 text-[12px]">
        <span class="text-base leading-none" aria-hidden="true">${headerIcon}</span>
        <span class="text-sm font-semibold text-[var(--text-body)]">${connectorName}</span>
        ${connector?.bot_user_name
          ? html`<span class="text-[var(--text-dim)]">· ${connector.bot_user_name}</span>`
          : null}
        <span class="text-[var(--text-dim)]">·</span>
        <span class=${`inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.14em] ${directTone}`}>
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
                  class="cursor-pointer rounded border border-rose-400/30 bg-rose-500/12 px-2 py-0.5 text-[10px] uppercase tracking-[0.14em] text-rose-100 hover:bg-rose-500/20 disabled:opacity-50"
                  disabled=${actionLoading.value}
                  aria-label=${`stop ${connectorName} sidecar`}
                  onClick=${() => { void stopSidecar(connectorId) }}
                >${actionLoading.value ? '…' : 'Stop'}</button>
              `
            : null}
          <${SidecarLogToggle} connectorId=${connectorId} />
          <${ConnectorConfigToggle} connectorId=${connectorId} />
          ${sidecarLogPath
            ? html`<span class="cursor-help text-[10px] text-[var(--text-dim)]" title=${sidecarLogPath}>↗</span>`
            : null}
          <button
            type="button"
            class="cursor-pointer rounded border border-[var(--white-8)] px-1.5 text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)]"
            aria-label="toggle header details"
            onClick=${() => { headerExpanded.value = !headerExpanded.value }}
          >${headerExpanded.value ? '▴' : '▾'}</button>
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
              if (connector?.available === true) {
                void stopSidecar(connectorId)
              } else {
                void startSidecar(connectorId)
              }
            },
            expandHeader: () => { headerExpanded.value = true },
            scrollToBindings: () => {
              const el = document.getElementById(`keepers-${connectorId}`)
              if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
            },
          },
        )}
      />

      ${headerExpanded.value
        ? html`
            <div class="mt-2 rounded-md border border-[var(--white-8)] bg-[var(--white-4)] p-3 text-[11px]">
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
              <div class="mt-3 flex flex-wrap gap-3 text-[10px] text-[var(--text-dim)]">
                <span>guilds ${connector?.guild_count ?? 0}</span>
                <span>gate ${gateHealthLabel}</span>
                <span>source ${connector?.binding_source || 'unknown'}</span>
                <span>runtime bindings ${connector?.runtime_bindings_count ?? configuredBindings.length}</span>
                <span>keeper dir ${keepers.length}</span>
              </div>
              <div class="mt-3">
                <${ActionButton} variant="ghost" size="sm" disabled=${loading || actionLoading.value} onClick=${() => { void refresh() }}>Refresh<//>
              </div>
            </div>
          `
        : null}

      ${connectorError || connector?.error
        ? html`<div class="mt-3 rounded-md border border-amber-400/20 bg-amber-500/8 px-3 py-2 text-[11px] text-amber-100">${connectorError ?? connector?.error}</div>`
        : null}

      <${SidecarLogViewer} connectorId=${connectorId} />
      <${ConnectorConfigForm} connectorId=${connectorId} />

      ${keeperDirectoryError && keepers.length === 0
        ? html`<div class="mt-3 rounded-md border border-amber-400/20 bg-amber-500/8 px-3 py-2 text-[11px] text-amber-100">keeper directory unavailable, manual entry only</div>`
        : null}

      ${showNoKeeperEmpty
        ? html`
            <div class="mt-3 rounded-md border border-dashed border-[var(--white-8)] bg-[var(--white-4)] px-3 py-3 text-[12px]">
              <div class="font-medium text-[var(--text-body)]">No keepers configured</div>
              <div class="mt-1 text-[10px] text-[var(--text-dim)]">
                Add keeper config files under config/keepers/ and restart the server.
              </div>
            </div>
          `
        : null}

      ${showSidecarOffEmpty
        ? (() => {
            const cmds = sidecarCommands(connectorId)
            return html`
              <div class="mt-3 rounded-md border border-dashed border-[var(--white-8)] bg-[var(--white-4)] px-3 py-3 text-[12px]">
                <div class="mb-1 flex items-center justify-between gap-2">
                  <div class="font-medium text-[var(--text-body)]">Sidecar not started</div>
                  <div class="flex items-center gap-2">
                    <${ActionButton}
                      variant="primary"
                      size="sm"
                      disabled=${actionLoading.value}
                      onClick=${() => { void startSidecar(connectorId) }}
                    >${actionLoading.value ? '...' : 'Start'}<//>
                    <span class="text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">${connectorName}</span>
                  </div>
                </div>
                <div class="text-[11px] text-[var(--text-dim)]">
                  Click <strong>Start</strong> to spawn via the backend, or copy the command below to run it from a terminal.
                </div>
                <div class="mt-2 grid grid-cols-1 gap-1.5">
                  <${CopyableCode} label="start" command=${cmds.start} />
                  <${CopyableCode} label="tail logs" command=${cmds.tail} />
                  <${CopyableCode} label="status" command=${cmds.status} />
                  <${CopyableCode} label="stop" command=${cmds.stop} />
                </div>
                <${SetupGuideCard} connectorId=${connectorId} />
              </div>
            `
          })()
        : null}

      ${knownGroups.length > 0
        ? html`
            <div class="mt-3 space-y-2" id=${`keepers-${connectorId}`}>
              ${knownGroups.map(group => {
                const keeper = group.keeper
                const expanded = expandedKeeperFor.value === group.name
                const toggleExpand = () => {
                  if (expanded) {
                    expandedKeeperFor.value = null
                  } else {
                    expandedKeeperFor.value = group.name
                    channelDraft.value = ''
                  }
                }
                return html`
                  <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2" data-keeper=${group.name}>
                    <div class="flex flex-wrap items-baseline gap-3">
                      <div class="text-sm font-medium text-[var(--text-body)]">${group.name}</div>
                      ${keeper
                        ? html`
                            <div class="text-[10px] text-[var(--text-dim)]">
                              status ${keeper.status || 'unknown'}
                              ${modelLabelForKeeper(keeper) ? ` · model ${modelLabelForKeeper(keeper)}` : ''}
                              ${runtimeLabelForKeeper(keeper) ? ` · runtime ${runtimeLabelForKeeper(keeper)}` : ''}
                            </div>
                          `
                        : null}
                    </div>

                    ${group.bindings.length === 0
                      ? html`<div class="mt-1 text-[11px] text-[var(--text-dim)]">(no channels)</div>`
                      : html`
                          <div class="mt-2 space-y-1">
                            ${group.bindings.map(binding => {
                              const humanized = humanizeChannel(names, binding.channel_id)
                              return html`
                                <div class="flex items-center justify-between gap-3 text-[12px]" data-channel-id=${binding.channel_id}>
                                  <div class="min-w-0 text-[var(--text-body)]">
                                    <span class="mr-1 text-[var(--text-dim)]">·</span>
                                    ${humanized
                                      ? html`<span>${humanized}</span>`
                                      : html`<span class="text-[var(--text-dim)]" title="sidecar has not sent names yet">names pending</span>`}
                                    <span class="ml-2 text-[10px] text-[var(--text-dim)]">(${truncateMiddle(binding.channel_id, 14)})</span>
                                  </div>
                                  ${bindingActionsEnabled
                                    ? html`
                                        <${ActionButton}
                                          variant="ghost"
                                          size="sm"
                                          disabled=${actionLoading.value}
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
                              class="cursor-pointer text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)]"
                              aria-label=${`add channel to ${group.name}`}
                              onClick=${toggleExpand}
                            >${expanded ? '− close' : '+ add channel'}</button>
                          </div>
                          ${expanded
                            ? html`
                                <div class="mt-2 rounded border border-dashed border-[var(--white-8)] bg-[var(--white-2)] p-2">
                                  <${TextInput}
                                    value=${channelDraft.value}
                                    placeholder=${`Paste ${connectorName} channel ID — right-click a channel → Copy ID`}
                                    ariaLabel=${`${connectorName} channel id`}
                                    onInput=${(e: Event) => { channelDraft.value = (e.target as HTMLInputElement).value }}
                                  />
                                  ${channelDraft.value.trim() && humanizeChannel(names, channelDraft.value.trim())
                                    ? html`<div class="mt-1 text-[10px] text-[var(--text-dim)]">resolves to ${humanizeChannel(names, channelDraft.value.trim())}</div>`
                                    : null}
                                  ${observedRooms.length > 0
                                    ? html`
                                        <div class="mt-2 flex flex-wrap gap-1.5">
                                          ${observedRooms.slice(0, 8).map(roomId => {
                                            const humanized = humanizeChannel(names, roomId)
                                            return html`
                                              <button
                                                type="button"
                                                class="cursor-pointer rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] text-[var(--text-body)] hover:bg-[var(--white-8)]"
                                                title=${roomId}
                                                onClick=${() => { channelDraft.value = roomId }}
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
                                      disabled=${actionLoading.value || channelDraft.value.trim().length === 0}
                                      onClick=${() => { void bindConnector(connectorId, group.name, channelDraft.value.trim()) }}
                                    >${actionLoading.value ? 'Applying...' : 'bind'}<//>
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
                <div class="rounded-md border border-amber-400/30 bg-amber-500/8 px-3 py-2" data-keeper=${group.name}>
                  <div class="flex items-baseline gap-2">
                    <span class="text-amber-300">⚠</span>
                    <div class="min-w-0">
                      <div class="text-sm font-medium text-[var(--text-body)]">${group.name}</div>
                      <div class="text-[10px] text-amber-200/90">binding references undefined keeper</div>
                    </div>
                  </div>
                  <div class="mt-2 space-y-1">
                    ${group.bindings.map(binding => {
                      const humanized = humanizeChannel(names, binding.channel_id)
                      return html`
                        <div class="flex items-center justify-between gap-3 text-[12px]" data-channel-id=${binding.channel_id}>
                          <div class="min-w-0 text-[var(--text-body)]">
                            <span class="mr-1 text-[var(--text-dim)]">·</span>
                            ${humanized
                              ? html`<span>${humanized}</span>`
                              : html`<span class="text-[var(--text-dim)]">names pending</span>`}
                            <span class="ml-2 text-[10px] text-[var(--text-dim)]">(${truncateMiddle(binding.channel_id, 14)})</span>
                          </div>
                          ${bindingActionsEnabled
                            ? html`
                                <${ActionButton}
                                  variant="ghost"
                                  size="sm"
                                  disabled=${actionLoading.value}
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
            <div class="mt-4 flex flex-wrap gap-3 text-[10px] text-[var(--text-dim)]">
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
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-lg">${channelIcon(ch.channel)}</span>
          <div>
            <div class="text-sm font-medium text-[var(--text-body)]">${ch.channel}</div>
            <div class="text-[10px] uppercase tracking-[0.18em] text-[var(--text-dim)]">
              ${ch.last_keeper ? `keeper ${ch.last_keeper}` : 'no keeper yet'}
            </div>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <div class="h-2 w-2 rounded-full" style="background: ${tone.dot}"></div>
          <span class=${`rounded-full px-2 py-1 text-[10px] uppercase tracking-[0.16em] ${tone.badge}`}>
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

      <div class="mt-3 grid grid-cols-2 gap-2 text-[11px] text-[var(--text-dim)]">
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
            <div class="mt-3 rounded-md border border-rose-400/20 bg-rose-500/8 px-3 py-2 text-[11px] text-rose-100">
              <div class="mb-1 uppercase tracking-[0.16em] text-rose-200/80">
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
    <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-xs font-medium text-[var(--text-body)]">
            ${binding.channel} · room ${truncateMiddle(binding.room_id)}
          </div>
          <div class="text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">
            ${binding.keeper ? `keeper ${binding.keeper}` : 'keeper pending'}
          </div>
        </div>
        <span class=${`rounded-full px-2 py-1 text-[10px] uppercase tracking-[0.16em] ${tone.badge}`}>
          ${tone.label}
        </span>
      </div>
      <div class="mt-2 grid grid-cols-3 gap-2 text-[11px] text-[var(--text-dim)]">
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
      <div class="mt-1 text-[11px] text-[var(--text-dim)]">
        recent activity <span class="font-mono text-[var(--text-body)]">${timeAgo(binding.last_activity)}</span>
      </div>
      ${lastError
        ? html`
            <div class="mt-2 rounded border border-rose-400/20 bg-rose-500/8 px-2 py-1 text-[10px] text-rose-100">
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
    ? 'border border-rose-400/30 bg-rose-500/12 text-rose-100'
    : 'border border-[var(--white-8)] bg-[var(--white-4)] text-[var(--text-dim)]'

  return html`
    <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 text-[11px] text-[var(--text-dim)]">
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
        <span class=${`rounded-full px-2 py-1 text-[10px] uppercase tracking-[0.16em] ${badgeClass}`}>
          ${event.outcome}
        </span>
      </div>
      ${event.error
        ? html`
            <div class="mt-2 text-[10px] text-rose-100">
              ${event.error_kind || 'error'} · ${shortText(event.error, 96)}
            </div>
          `
        : null}
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
    return html`<${LoadingState}>커넥터 상태 불러오는 중...<//>`
  }

  if (snapshot.gateError && !d && visibleConnectors.length === 0) {
    return html`<${ErrorState} message=${`Gate: ${snapshot.gateError}`} />`
  }

  if (filterId && allConnectors.length > 0 && visibleConnectors.length === 0) {
    return html`
      <div class="rounded-md border border-dashed border-[var(--white-8)] px-3 py-6 text-center text-xs text-[var(--text-dim)]">
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

  // Progress hint for the "전체" view: how many of the 4 known sidecars
  // are currently advertising a 'connected' state. Hidden in single-bridge
  // sub-sections — the per-panel status dot already conveys that.
  const knownConnectedCount = allConnectors.filter(
    c => (KNOWN_CONNECTOR_IDS as readonly string[]).includes(c.connector_id)
      && connectorStateLabel(c) === 'connected',
  ).length

  return html`
    <div>
      <div class="mb-3 flex items-center justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold text-[var(--text-body)]">${filterId ? CONNECTOR_DISPLAY_NAMES[filterId as KnownConnectorId] ?? '커넥터' : '커넥터'}</h3>
          <div class="mt-1 text-[11px] text-[var(--text-dim)]">
            ${filterId
              ? `${CONNECTOR_DISPLAY_NAMES[filterId as KnownConnectorId] ?? filterId} sidecar의 라이브 상태와 keeper 바인딩.`
              : '4종 채널 sidecar(Discord, iMessage, Slack, Telegram)의 라이브 상태와 keeper 바인딩을 한 곳에서.'}
          </div>
        </div>
        <div class="text-right text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">
          ${!filterId
            ? (() => {
                const allUp = knownConnectedCount === KNOWN_CONNECTOR_IDS.length
                const tone = allUp ? 'text-emerald-300' : ''
                return html`<div class=${tone}>${knownConnectedCount}/${KNOWN_CONNECTOR_IDS.length} connected</div>`
              })()
            : null}
          <div>${d ? `success ${d.success_rate_pct}%` : `${visibleConnectors.length} connector${visibleConnectors.length !== 1 ? 's' : ''}`}</div>
          <div>${d ? `uptime ${formatUptime(d.uptime_seconds)}` : 'gate metrics unavailable'}</div>
        </div>
      </div>

      ${visibleConnectors.map(c => html`
        <${ConnectorLivePanel}
          connector=${c}
          gate=${d}
          keepers=${snapshot.keepers}
          connectorError=${snapshot.connectorError}
          keeperDirectoryError=${snapshot.keeperError}
          loading=${loading}
        />
      `)}

      ${snapshot.gateError
        ? html`
            <div class="mb-4 rounded-md border border-amber-400/20 bg-amber-500/8 px-3 py-2 text-[11px] text-amber-100">
              Gate metrics unavailable: ${snapshot.gateError}
            </div>
          `
        : null}

      ${!d
        ? html`
            <div class="rounded-md border border-dashed border-[var(--white-8)] px-3 py-4 text-xs text-[var(--text-dim)]">
              Gate-advertised connector runtime is visible, but Gate-observed traffic is not available yet.
            </div>
          `
        : html`
            <div>
              <div class="mb-3 grid grid-cols-4 gap-2 max-[720px]:grid-cols-2">
                <${StatCard} label="Messages" value=${d.total_messages} />
                <${StatCard} label="Success" value=${d.total_success} />
                <${StatCard} label="Errors" value=${d.total_errors} />
                <${StatCard} label="Dedup Keys" value=${d.dedup_table_size} />
              </div>

              <div class="mb-4 grid grid-cols-2 gap-2 text-[11px] text-[var(--text-dim)] max-[720px]:grid-cols-1">
                <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
                  duplicate suppressions
                  <span class="ml-2 font-mono text-[var(--text-body)]">${d.total_duplicates}</span>
                </div>
                <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
                  active connectors
                  <span class="ml-2 font-mono text-[var(--text-body)]">${d.channels.length}</span>
                </div>
              </div>

              <div class="mb-4 grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
                <div>
                  <div class="mb-2 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">
                    Observed room bindings
                  </div>
                  ${d.bindings.length === 0
                    ? html`<div class="rounded-md border border-dashed border-[var(--white-8)] px-3 py-4 text-xs text-[var(--text-dim)]">관찰된 room 바인딩 없음</div>`
                    : html`
                        <div class="space-y-2">
                          ${d.bindings.slice(0, 6).map(binding => html`<${BindingRow} binding=${binding} />`)}
                        </div>
                      `}
                </div>

                <div>
                  <div class="mb-2 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">
                    Recent gate events
                  </div>
                  ${d.recent_events.length === 0
                    ? html`<div class="rounded-md border border-dashed border-[var(--white-8)] px-3 py-4 text-xs text-[var(--text-dim)]">커넥터 이벤트 기록 없음</div>`
                    : html`
                        <div class="space-y-2">
                          ${d.recent_events.slice(0, 8).map(event => html`<${EventRow} event=${event} />`)}
                        </div>
                      `}
                </div>
              </div>

              ${d.channels.length === 0
                ? html`<div class="py-4 text-center text-xs text-[var(--text-dim)]">활성 커넥터 없음</div>`
                : html`
                    <div class="grid grid-cols-2 gap-2 max-[900px]:grid-cols-1">
                      ${d.channels.map(ch => html`<${ChannelCard} ch=${ch} />`)}
                    </div>
                  `}
            </div>
          `}
    </div>
  `
}

export function resetConnectorStatusState() {
  connectorStatusResource.reset(EMPTY_SNAPSHOT)
  actionLoading.value = false
  channelDraft.value = ''
  expandedKeeperFor.value = null
  headerExpanded.value = false
}

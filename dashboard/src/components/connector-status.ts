// Connector Status — Channel Gate per-channel diagnostics panel.
// Shows connector health, success rate, duplicates, and latest failure context.

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
import { Select } from './common/select'
import { showToast } from './common/toast'
import { createManagedAsyncResource } from '../lib/async-state'

const actionLoading = signal(false)
const channelDraft = signal('')
const keeperDraft = signal('')

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

function preferredConnector(payload: GateConnectorsData | null): GateConnectorInfo | null {
  if (!payload || payload.connectors.length === 0) return null
  return payload.connectors.find(connector => connector.capabilities.includes('bindings')) ?? payload.connectors[0] ?? null
}

async function refresh() {
  const snapshot = await connectorStatusResource.load(async (signal, previous) => {
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

  const primaryConnector = preferredConnector(snapshot?.connectors ?? null)
  if (!channelDraft.value && (primaryConnector?.configured_bindings.length ?? 0) > 0) {
    channelDraft.value = primaryConnector?.configured_bindings[0]?.channel_id ?? ''
  }
  if (!keeperDraft.value && (primaryConnector?.configured_bindings.length ?? 0) > 0) {
    keeperDraft.value = primaryConnector?.configured_bindings[0]?.keeper_name ?? ''
  }
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

function channelIcon(ch: string): string {
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

function keeperLabel(keeper: GateKeeperInfo): string {
  const status = keeper.status?.trim() || 'unknown'
  const model = modelLabelForKeeper(keeper)
  const runtime = runtimeLabelForKeeper(keeper)
  return [keeper.name, status, model, runtime].filter(Boolean).join(' · ')
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

async function bindConnector(connectorId: string) {
  const channelId = channelDraft.value.trim()
  const keeperName = keeperDraft.value.trim()
  if (!channelId || !keeperName) return

  actionLoading.value = true
  try {
    await post(`/api/v1/gate/connector/bind?name=${encodeURIComponent(connectorId)}`, {
      channel_id: channelId,
      keeper_name: keeperName,
    })
    await refresh()
    showToast(`Bound ${channelId} -> ${keeperName}`, 'success')
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'bind failed', 'error')
  } finally {
    actionLoading.value = false
  }
}

async function unbindConnector(connectorId: string, channelIdOverride?: string) {
  const channelId = (channelIdOverride ?? channelDraft.value).trim()
  if (!channelId) return

  actionLoading.value = true
  try {
    await post(`/api/v1/gate/connector/unbind?name=${encodeURIComponent(connectorId)}`, {
      channel_id: channelId,
    })
    if (channelDraft.value.trim() === channelId) {
      channelDraft.value = ''
    }
    await refresh()
    showToast(`Unbound ${channelId}`, 'success')
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'unbind failed', 'error')
  } finally {
    actionLoading.value = false
  }
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
  const keeperByName = new Map(keepers.map(keeper => [keeper.name, keeper] as const))
  const configuredBindings = connector?.configured_bindings ?? []
  const audit = connector?.recent_audit ?? []
  const observedRooms = uniqueStrings([
    ...(gate?.bindings ?? [])
      .filter(binding => binding.channel === (connector?.channel ?? ''))
      .map(binding => binding.room_id),
    ...(gate?.recent_events ?? [])
      .filter(event => event.channel === (connector?.channel ?? ''))
      .map(event => event.room_id),
    ...configuredBindings.map(binding => binding.channel_id),
  ])
  const suggestedKeepers = uniqueStrings([
    ...(gate?.bindings ?? [])
      .filter(binding => binding.channel === (connector?.channel ?? ''))
      .map(binding => binding.keeper),
    ...(gate?.recent_events ?? [])
      .filter(event => event.channel === (connector?.channel ?? ''))
      .map(event => event.keeper),
    ...configuredBindings.map(binding => binding.keeper_name),
  ])
  const selectedKeeper = keeperByName.get(keeperDraft.value.trim()) ?? null
  const directLabel = connectorStateLabel(connector)
  const directTone = connectorStateTone(connector)
  const bindingActionsEnabled =
    connector != null && connector.capabilities.includes('bindings')
  const connectorName = connector?.display_name || 'Connector'
  const connectorId = connector?.connector_id ?? ''
  const channelInputLabel = `${connectorName} channel id`
  let gateHealthLabel = 'unknown'
  if (connector?.gate_healthy === true) {
    gateHealthLabel = 'healthy'
  } else if (connector?.gate_healthy === false) {
    gateHealthLabel = 'unhealthy'
  }

  const names = connector?.names
  const sidecarLogPath = connector?.names_path
    ? connector.names_path.replace(
        /\/\.masc\/connectors\/[^/]+\/names\.json$/,
        `/.masc/logs/${connectorId}-sidecar-YYYYMMDD.log`,
      )
    : ''

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

  const showOnboarding =
    configuredBindings.length === 0 && !connector?.available && !connectorError

  return html`
    <div class="mb-4 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(135deg,rgba(88,101,242,0.16),rgba(88,101,242,0.04))] p-4">
      <div class="mb-3 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2 text-[11px] text-[var(--text-body)]">
        ${livenessDots.map(dot => html`
          <div class="flex min-w-0 items-center gap-2" title=${dot.hint}>
            <span class=${`inline-block h-2 w-2 rounded-full ${dotClass(dot.state)}`}></span>
            <span class="font-medium">${dot.label}</span>
            <span class="truncate text-[var(--text-dim)]">${dot.detail}</span>
            ${dot.hint && (dot.state === 'down' || dot.state === 'warn')
              ? html`<span class="text-[10px] italic text-[var(--text-dim)]">— ${dot.hint}</span>`
              : null}
          </div>
        `)}
      </div>

      ${showOnboarding
        ? html`
            <div class="mb-3 rounded-md border border-dashed border-[var(--white-8)] bg-[var(--white-4)] px-3 py-3 text-[12px] text-[var(--text-body)]">
              <div class="mb-2 text-[11px] font-semibold uppercase tracking-[0.18em] text-[var(--text-dim)]">
                Connect ${connectorName} in 3 steps
              </div>
              <ol class="mb-2 list-decimal pl-5 text-[11px] leading-5 text-[var(--text-dim)]">
                <li>Start the MASC server (the dashboard you're reading confirms it's running).</li>
                <li>Start the sidecar: <code class="rounded bg-[var(--white-8)] px-1">cd sidecars/${connectorId}-bot && ./run.sh</code></li>
                <li>Come back to this panel and bind a channel below.</li>
              </ol>
              <div class="text-[10px] text-[var(--text-dim)]">
                Once the sidecar emits its first heartbeat this card disappears.
              </div>
            </div>
          `
        : null}

      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-[var(--text-dim)]">Gate-Advertised Connector</div>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <span class=${`rounded-full border px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.16em] ${directTone}`}>
              ${directLabel}
            </span>
            <span class="text-[13px] font-medium text-[var(--text-body)]">
              ${connector?.bot_user_name
                ? `${connectorName} · ${connector.bot_user_name} · ${truncateMiddle(connector.bot_user_id, 24)}`
                : `${connectorName} runtime has not reported identity yet`}
            </span>
          </div>
          <div class="mt-2 flex flex-wrap gap-3 text-[11px] text-[var(--text-dim)]">
            <span>heartbeat ${timeAgo(connector?.updated_at ?? '')}</span>
            <span>ready ${timeAgo(connector?.last_ready_at ?? '')}</span>
            <span>guilds ${connector?.guild_count ?? 0}</span>
            <span>runtime bindings ${connector?.runtime_bindings_count ?? configuredBindings.length}</span>
            ${connector?.reply_mode ? html`<span>reply ${connector.reply_mode}</span>` : null}
            ${connector?.self_chat_guid ? html`<span>self-chat ${truncateMiddle(connector.self_chat_guid, 28)}</span>` : null}
            <span>source ${connector?.binding_source || 'unknown'}</span>
            <span>keeper dir ${keepers.length}</span>
            <span>
              gate ${gateHealthLabel}
            </span>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <${ActionButton} variant="ghost" size="sm" disabled=${loading || actionLoading.value} onClick=${() => { void refresh() }}>Refresh<//>
          ${bindingActionsEnabled
            ? html`
                <${ActionButton}
                  variant="primary"
                  size="sm"
                  disabled=${actionLoading.value || channelDraft.value.trim().length === 0 || keeperDraft.value.trim().length === 0}
                  onClick=${() => { void bindConnector(connectorId) }}
                >
                  ${actionLoading.value ? 'Applying...' : 'Bind'}
                <//>
                <${ActionButton}
                  variant="danger"
                  size="sm"
                  disabled=${actionLoading.value || channelDraft.value.trim().length === 0}
                  onClick=${() => { void unbindConnector(connectorId) }}
                >
                  Unbind
                <//>
              `
            : null}
        </div>
      </div>

      ${connectorError || connector?.error
        ? html`<div class="mt-3 rounded-md border border-amber-400/20 bg-amber-500/8 px-3 py-2 text-[11px] text-amber-100">${connectorError ?? connector?.error}</div>`
        : null}

      ${connector
        ? html`
            <div class="mt-3 flex flex-wrap gap-3 text-[10px] text-[var(--text-dim)]">
              <span>status ${connector.status_path || '-'}</span>
              <span>bindings ${connector.binding_store_path || '-'}</span>
              <span>audit ${connector.audit_path || '-'}</span>
              <span>names ${connector.names_path || '-'}</span>
              ${sidecarLogPath
                ? html`<span>sidecar logs ${sidecarLogPath}</span>`
                : null}
            </div>
          `
        : null}

      <div class="mt-4 grid grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)] gap-4 max-[980px]:grid-cols-1">
        <div class="space-y-3 rounded-md border border-dashed border-[var(--white-8)] p-3">
          <div>
            <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-[var(--text-body)]">Create / replace binding</div>
            <div class="mt-1 text-[10px] text-[var(--text-dim)]">
              Existing bindings are listed on the right. Paste a channel ID and pick a keeper here to add or replace a binding.
            </div>
          </div>
          <div>
            <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Channel ID (draft)</div>
            <${TextInput}
              value=${channelDraft.value}
              placeholder=${`Paste ${connectorName} channel ID — right-click a channel → Copy ID`}
              ariaLabel=${channelInputLabel}
              onInput=${(e: Event) => { channelDraft.value = (e.target as HTMLInputElement).value }}
            />
            ${channelDraft.value.trim() && humanizeChannel(names, channelDraft.value.trim())
              ? html`<div class="mt-1 text-[10px] text-[var(--text-dim)]">resolves to ${humanizeChannel(names, channelDraft.value.trim())}</div>`
              : null}
          </div>
          <div>
            <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Keeper</div>
            ${keepers.length > 0
              ? html`
                  <div class="mb-2">
                    <${Select}
                      value=${selectedKeeper?.name ?? ''}
                      options=${keepers.map(keeper => ({ value: keeper.name, label: keeperLabel(keeper) }))}
                      placeholder="keeper 선택"
                      onInput=${(value: string) => { keeperDraft.value = value }}
                    />
                  </div>
                `
              : null}
            <${TextInput}
              value=${keeperDraft.value}
              placeholder="keeper name"
              ariaLabel="Keeper name"
              onInput=${(e: Event) => { keeperDraft.value = (e.target as HTMLInputElement).value }}
            />
            ${selectedKeeper
              ? html`
                  <div class="mt-2 flex flex-wrap gap-2 text-[10px] text-[var(--text-dim)]">
                    <span>status ${selectedKeeper.status || 'unknown'}</span>
                    ${modelLabelForKeeper(selectedKeeper) ? html`<span>model ${modelLabelForKeeper(selectedKeeper)}</span>` : null}
                    ${runtimeLabelForKeeper(selectedKeeper) ? html`<span>runtime ${runtimeLabelForKeeper(selectedKeeper)}</span>` : null}
                    ${selectedKeeper.keepalive_running ? html`<span>keepalive</span>` : null}
                  </div>
                `
              : null}
            ${keepers.length === 0 && keeperDirectoryError
              ? html`
                  <div class="mt-2 text-[10px] text-[var(--text-dim)]">
                    keeper directory unavailable, manual entry only
                  </div>
                `
              : null}
          </div>
          ${observedRooms.length > 0
            ? html`
                <div>
                  <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Observed rooms</div>
                  <div class="flex flex-wrap gap-2">
                    ${observedRooms.slice(0, 8).map(roomId => {
                      const humanized = humanizeChannel(names, roomId)
                      return html`
                      <button
                        type="button"
                        class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-1 text-[10px] text-[var(--text-body)] cursor-pointer hover:bg-[var(--white-8)]"
                        title=${roomId}
                        onClick=${() => { channelDraft.value = roomId }}
                      >
                        ${humanized
                          ? html`<span>${humanized}</span><span class="ml-1 text-[var(--text-dim)]">· ${truncateMiddle(roomId, 10)}</span>`
                          : truncateMiddle(roomId, 22)}
                      </button>
                    `})}
                  </div>
                </div>
              `
            : null}
          ${suggestedKeepers.length > 0
            ? html`
                <div>
                  <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Suggested keepers</div>
                  <div class="flex flex-wrap gap-2">
                    ${suggestedKeepers.slice(0, 8).map(name => html`
                      <button
                        type="button"
                        class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-1 text-[10px] text-[var(--text-body)] cursor-pointer hover:bg-[var(--white-8)]"
                        onClick=${() => { keeperDraft.value = name }}
                      >
                        ${name}
                      </button>
                    `)}
                  </div>
                </div>
              `
            : null}
        </div>

        <div class="space-y-3">
          <div>
            <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Configured bindings</div>
            ${configuredBindings.length === 0
              ? html`<div class="rounded-md border border-dashed border-[var(--white-8)] px-3 py-4 text-xs text-[var(--text-dim)]">No persisted connector bindings yet</div>`
              : html`
                  <div class="space-y-2">
                    ${configuredBindings.map(binding => html`
                      ${(() => {
                        const keeperMeta = keeperByName.get(binding.keeper_name) ?? null
                        const humanized = humanizeChannel(names, binding.channel_id)
                        return html`
                      <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
                        <div class="flex items-start justify-between gap-3">
                          <div class="min-w-0">
                            <div class="text-xs font-medium text-[var(--text-body)]">
                              <code>${truncateMiddle(binding.channel_id, 26)}</code>
                              ${humanized
                                ? html`<span class="ml-2 text-[var(--text-dim)]">— ${humanized}</span>`
                                : html`<span class="ml-2 text-[var(--text-dim)]">— <span title="sidecar has not sent names yet">names pending</span></span>`}
                            </div>
                            <div class="text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">keeper ${binding.keeper_name}</div>
                            ${keeperMeta
                              ? html`
                                  <div class="mt-1 text-[10px] text-[var(--text-dim)]">
                                    ${keeperMeta.status || 'unknown'}
                                    ${modelLabelForKeeper(keeperMeta) ? ` · ${modelLabelForKeeper(keeperMeta)}` : ''}
                                    ${runtimeLabelForKeeper(keeperMeta) ? ` · ${runtimeLabelForKeeper(keeperMeta)}` : ''}
                                  </div>
                                `
                              : null}
                          </div>
                          <div class="flex gap-2">
                            <${ActionButton} variant="ghost" size="sm" onClick=${() => {
                              channelDraft.value = binding.channel_id
                              keeperDraft.value = binding.keeper_name
                            }}>Use<//>
                            ${bindingActionsEnabled
                              ? html`<${ActionButton} variant="danger" size="sm" disabled=${actionLoading.value} onClick=${() => { void unbindConnector(connectorId, binding.channel_id) }}>Unbind<//>`
                              : null}
                          </div>
                        </div>
                      </div>
                        `
                      })()}
                    `)}
                  </div>
                `}
          </div>
          ${audit.length > 0
            ? html`
                <div>
                  <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Recent binding audit</div>
                  <div class="space-y-2">
                    ${audit.slice(0, 4).map(entry => html`
                      ${(() => {
                        const keeperMeta = keeperByName.get(entry.keeper_name) ?? null
                        const humanized = humanizeChannel(names, entry.channel_id)
                        return html`
                      <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2 text-[11px] text-[var(--text-dim)]">
                        <div class="font-medium text-[var(--text-body)]">${entry.action} · ${truncateMiddle(entry.channel_id, 22)} · ${entry.keeper_name}</div>
                        ${humanized
                          ? html`<div class="mt-0.5 text-[10px] text-[var(--text-dim)]">${humanized}</div>`
                          : null}
                        ${keeperMeta && (keeperMeta.status || modelLabelForKeeper(keeperMeta) || runtimeLabelForKeeper(keeperMeta))
                          ? html`
                              <div class="mt-1 text-[10px]">
                                ${keeperMeta.status || 'unknown'}
                                ${modelLabelForKeeper(keeperMeta) ? ` · ${modelLabelForKeeper(keeperMeta)}` : ''}
                                ${runtimeLabelForKeeper(keeperMeta) ? ` · ${runtimeLabelForKeeper(keeperMeta)}` : ''}
                              </div>
                            `
                          : null}
                        <div class="mt-1">${entry.actor_name || 'dashboard'} · ${timeAgo(entry.timestamp)}</div>
                      </div>
                        `
                      })()}
                    `)}
                  </div>
                </div>
              `
            : null}
        </div>
      </div>
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

  if (loading && !d && allConnectors.length === 0) {
    return html`<${LoadingState}>커넥터 상태 불러오는 중...<//>`
  }

  if (snapshot.gateError && !d && allConnectors.length === 0) {
    return html`<${ErrorState} message=${`Gate: ${snapshot.gateError}`} />`
  }

  if (!d && allConnectors.length === 0) return null

  return html`
    <div>
      <div class="mb-3 flex items-center justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold text-[var(--text-body)]">Channel Gate Connectors</h3>
          <div class="mt-1 text-[11px] text-[var(--text-dim)]">
            Gate advertises connector descriptors; traffic health comes from gate metrics.
          </div>
        </div>
        <div class="text-right text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">
          <div>${d ? `success ${d.success_rate_pct}%` : `${allConnectors.length} connector${allConnectors.length !== 1 ? 's' : ''}`}</div>
          <div>${d ? `uptime ${formatUptime(d.uptime_seconds)}` : 'gate metrics unavailable'}</div>
        </div>
      </div>

      ${allConnectors.map(c => html`
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
  keeperDraft.value = ''
}

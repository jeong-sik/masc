// Connector Status — Channel Gate per-channel diagnostics panel.
// Shows connector health, success rate, duplicates, and latest failure context.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get, post } from '../api/core'
import { formatElapsedCompact, formatTimeAgoEn } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { lastEvent } from '../sse'
import { StatCard } from './common/stat-card'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { Select } from './common/select'
import { showToast } from './common/toast'

interface ChannelInfo {
  channel: string
  message_count: number
  success_count: number
  error_count: number
  duplicate_count: number
  validation_error_count: number
  keeper_error_count: number
  dispatch_unavailable_count: number
  internal_error_count: number
  last_activity: string
  last_success: string
  last_error_at: string
  last_keeper: string
  last_room_id: string
  last_error: string
  last_error_kind: string
  last_outcome: string
  avg_duration_ms: number
  max_duration_ms: number
  slow_count: number
  slow_rate_pct: number
  success_rate_pct: number
  room_count: number
  health: 'idle' | 'healthy' | 'degraded' | 'failing' | string
}

interface GateStatusData {
  channels: ChannelInfo[]
  bindings: BindingInfo[]
  recent_events: GateEventInfo[]
  total_messages: number
  total_success: number
  total_errors: number
  total_duplicates: number
  success_rate_pct: number
  dedup_table_size: number
  uptime_seconds: number
}

interface GateKeeperInfo {
  name: string
  agent_name?: string
  status?: string
  model?: string
  active_model?: string
  primary_model?: string
  keepalive_running?: boolean
  last_turn_ago_s?: number | null
}

interface GateKeepersData {
  count: number
  keepers: GateKeeperInfo[]
}

interface DiscordConfiguredBinding {
  channel_id: string
  keeper_name: string
}

interface DiscordAuditEntry {
  timestamp: string
  action: string
  guild_id: string
  channel_id: string
  keeper_name: string
  actor_id: string
  actor_name: string
  previous_keeper: string
}

interface ConnectorStoragePaths {
  status_path: string
  binding_store_path: string
  audit_path: string
}

interface ConnectorRuntimeSummary {
  available: boolean
  connected: boolean
  stale: boolean
  stale_after_sec: number
  status: string
  error: string
  updated_at: string
  last_ready_at: string
  bot_user_name: string
  bot_user_id: string
  guild_count: number
  gate_base_url: string
  gate_healthy: boolean | null
  gate_health_checked_at: string
  pid: number
}

interface ConnectorBindingSummary {
  binding_source: string
  runtime_bindings_count: number
  configured_bindings_count: number
}

interface GateConnectorInfo {
  connector_id: string
  display_name: string
  channel: string
  capabilities: string[]
  status: string
  available: boolean
  connected: boolean
  stale: boolean
  stale_after_sec: number
  error: string
  status_path: string
  binding_store_path: string
  audit_path: string
  updated_at: string
  last_ready_at: string
  bot_user_name: string
  bot_user_id: string
  guild_count: number
  gate_base_url: string
  gate_healthy: boolean | null
  gate_health_checked_at: string
  binding_source: string
  runtime_bindings_count: number
  pid: number
  configured_bindings: DiscordConfiguredBinding[]
  recent_audit: DiscordAuditEntry[]
  storage_paths: ConnectorStoragePaths
  runtime_summary: ConnectorRuntimeSummary
  binding_summary: ConnectorBindingSummary
  observed_channel?: ChannelInfo | null
}

interface GateConnectorsData {
  connectors: GateConnectorInfo[]
  total: number
  active_count: number
  generated_at: string
}

interface BindingInfo {
  channel: string
  room_id: string
  keeper: string
  message_count: number
  success_count: number
  error_count: number
  duplicate_count: number
  last_activity: string
  last_success: string
  last_error_at: string
  last_error: string
  last_error_kind: string
  last_outcome: string
  avg_duration_ms: number
  max_duration_ms: number
  success_rate_pct: number
  health: 'idle' | 'healthy' | 'degraded' | 'failing' | string
}

interface GateEventInfo {
  seq: number
  timestamp: string
  channel: string
  room_id: string
  keeper: string
  outcome: string
  error_kind: string
  error: string
  duration_ms: number
}

const data = signal<GateStatusData | null>(null)
const connectorsData = signal<GateConnectorsData | null>(null)
const loading = signal(false)
const error = signal<string | null>(null)
const connectorError = signal<string | null>(null)
const keeperDirectory = signal<GateKeeperInfo[]>([])
const keeperDirectoryError = signal<string | null>(null)
const actionLoading = signal(false)
const channelDraft = signal('')
const keeperDraft = signal('')

let inflightRequest: Promise<void> | null = null
const GATE_KEEPERS_PATH = '/api/v1/gate/keepers?limit=50&detailed=true'
const GATE_CONNECTORS_PATH = '/api/v1/gate/connectors'

function preferredConnector(payload: GateConnectorsData | null): GateConnectorInfo | null {
  if (!payload || payload.connectors.length === 0) return null
  return payload.connectors.find(connector => connector.capabilities.includes('bindings')) ?? payload.connectors[0] ?? null
}

async function refresh() {
  if (inflightRequest) return
  loading.value = true
  inflightRequest = (async () => {
    try {
      const gateResult = await get<GateStatusData>('/api/v1/gate/status')
      data.value = gateResult
      error.value = null
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'fetch failed'
    }
    try {
      const connectorResult = await get<GateConnectorsData>(GATE_CONNECTORS_PATH)
      connectorsData.value = connectorResult
      connectorError.value = null
      const primaryConnector = preferredConnector(connectorResult)
      if (!channelDraft.value && (primaryConnector?.configured_bindings.length ?? 0) > 0) {
        channelDraft.value = primaryConnector?.configured_bindings[0]?.channel_id ?? ''
      }
      if (!keeperDraft.value && (primaryConnector?.configured_bindings.length ?? 0) > 0) {
        keeperDraft.value = primaryConnector?.configured_bindings[0]?.keeper_name ?? ''
      }
    } catch (e) {
      connectorError.value = e instanceof Error ? e.message : 'fetch failed'
    }
    try {
      const keepersResult = await get<GateKeepersData>(GATE_KEEPERS_PATH)
      keeperDirectory.value = keepersResult.keepers ?? []
      keeperDirectoryError.value = null
    } catch (e) {
      keeperDirectory.value = []
      keeperDirectoryError.value = e instanceof Error ? e.message : 'fetch failed'
    } finally {
      loading.value = false
      inflightRequest = null
    }
  })()
  return inflightRequest
}

const CHANNEL_ICONS: Record<string, string> = {
  discord: '\u{1F3AE}',
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

// Time formatting delegated to lib/format-time (SSOT)
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
    await post(`/api/v1/gate/connector/bind?name=${encodeURIComponent(connectorId)}`, { channel_id: channelId, keeper_name: keeperName })
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
    await post(`/api/v1/gate/connector/unbind?name=${encodeURIComponent(connectorId)}`, { channel_id: channelId })
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
}: {
  connector: GateConnectorInfo | null
  gate: GateStatusData | null
}) {
  const keepers = keeperDirectory.value
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
  const connectorId = connector?.connector_id ?? ''
  const bindingActionsEnabled =
    connectorId !== '' && connector?.capabilities.includes('bindings')
  const connectorName = connector?.display_name || 'Connector'
  const channelInputLabel = `${connectorName} channel id`

  return html`
    <div class="mb-4 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(135deg,rgba(88,101,242,0.16),rgba(88,101,242,0.04))] p-4">
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
            <span>source ${connector?.binding_source || 'unknown'}</span>
            <span>keeper dir ${keepers.length}</span>
            <span>
              gate ${connector?.gate_healthy == null ? 'unknown' : connector.gate_healthy ? 'healthy' : 'unhealthy'}
            </span>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <${ActionButton} variant="ghost" size="sm" disabled=${loading.value || actionLoading.value} onClick=${() => { void refresh() }}>Refresh<//>
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

      ${connectorError.value || connector?.error
        ? html`<div class="mt-3 rounded-md border border-amber-400/20 bg-amber-500/8 px-3 py-2 text-[11px] text-amber-100">${connectorError.value ?? connector?.error}</div>`
        : null}

      ${connector
        ? html`
            <div class="mt-3 flex flex-wrap gap-3 text-[10px] text-[var(--text-dim)]">
              <span>status ${connector.status_path || '-'}</span>
              <span>bindings ${connector.binding_store_path || '-'}</span>
              <span>audit ${connector.audit_path || '-'}</span>
            </div>
          `
        : null}

      <div class="mt-4 grid grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)] gap-4 max-[980px]:grid-cols-1">
        <div class="space-y-3">
          <div>
            <div class="mb-1 text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">Channel ID</div>
            <${TextInput}
              value=${channelDraft.value}
              placeholder=${`${connectorName} channel identifier`}
              ariaLabel=${channelInputLabel}
              onInput=${(e: Event) => { channelDraft.value = (e.target as HTMLInputElement).value }}
            />
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
            ${keepers.length === 0 && keeperDirectoryError.value
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
                    ${observedRooms.slice(0, 8).map(roomId => html`
                      <button
                        type="button"
                        class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-1 text-[10px] text-[var(--text-body)] cursor-pointer hover:bg-[var(--white-8)]"
                        onClick=${() => { channelDraft.value = roomId }}
                      >
                        ${truncateMiddle(roomId, 22)}
                      </button>
                    `)}
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
                        return html`
                      <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
                        <div class="flex items-start justify-between gap-3">
                          <div class="min-w-0">
                            <div class="text-xs font-medium text-[var(--text-body)]">${truncateMiddle(binding.channel_id, 26)}</div>
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
                        return html`
                      <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2 text-[11px] text-[var(--text-dim)]">
                        <div class="font-medium text-[var(--text-body)]">${entry.action} · ${truncateMiddle(entry.channel_id, 22)} · ${entry.keeper_name}</div>
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
    refresh()
  }, [])

  useEffect(() => {
    const event = lastEvent.value
    if (event && data.value) {
      const timer = setTimeout(refresh, 2000)
      return () => clearTimeout(timer)
    }
  }, [lastEvent.value])

  const d = data.value
  const live = preferredConnector(connectorsData.value)

  if (loading.value && !d && !live) {
    return html`<${LoadingState}>커넥터 상태 불러오는 중...<//>`
  }

  if (error.value && !d && !live) {
    return html`<div class="text-xs text-[var(--red)]">Gate: ${error.value}</div>`
  }

  if (!d && !live) return null

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
          <div>${d ? `success ${d.success_rate_pct}%` : `descriptor ${connectorStateLabel(live)}`}</div>
          <div>${d ? `uptime ${formatUptime(d.uptime_seconds)}` : 'gate metrics unavailable'}</div>
        </div>
      </div>

      <${ConnectorLivePanel} connector=${live} gate=${d} />

      ${error.value
        ? html`
            <div class="mb-4 rounded-md border border-amber-400/20 bg-amber-500/8 px-3 py-2 text-[11px] text-amber-100">
              Gate metrics unavailable: ${error.value}
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
  data.value = null
  connectorsData.value = null
  loading.value = false
  error.value = null
  connectorError.value = null
  keeperDirectory.value = []
  keeperDirectoryError.value = null
  actionLoading.value = false
  channelDraft.value = ''
  keeperDraft.value = ''
  inflightRequest = null
}

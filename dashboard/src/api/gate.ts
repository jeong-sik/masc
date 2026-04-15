import { get } from './core'
import {
  asBoolean,
  asNumber,
  asRecordArray,
  asString,
  asStringArray,
  isRecord,
} from '../components/common/normalize'

export interface ChannelInfo {
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
  health: string
}

export interface BindingInfo {
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
  health: string
}

export interface GateEventInfo {
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

export interface GateStatusData {
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

export interface GateKeeperInfo {
  name: string
  agent_name?: string
  status?: string
  model?: string
  active_model?: string
  primary_model?: string
  keepalive_running?: boolean
  last_turn_ago_s?: number | null
}

export interface GateKeepersData {
  count: number
  keepers: GateKeeperInfo[]
}

export interface DiscordConfiguredBinding {
  channel_id: string
  keeper_name: string
}

export interface DiscordAuditEntry {
  timestamp: string
  action: string
  guild_id: string
  channel_id: string
  keeper_name: string
  actor_id: string
  actor_name: string
  previous_keeper: string
}

export interface ConnectorStoragePaths {
  status_path: string
  binding_store_path: string
  audit_path: string
  names_path: string
}

export interface ConnectorNames {
  guild_names: Record<string, string>
  channel_names: Record<string, string>
  channel_to_guild: Record<string, string>
  updated_at: string
}

export interface ConnectorRuntimeSummary {
  available: boolean
  connected: boolean
  stale: boolean
  stale_after_sec: number
  status: string
  error: string
  updated_at: string
  reply_mode: string
  self_chat_guid: string
  last_ready_at: string
  bot_user_name: string
  bot_user_id: string
  guild_count: number
  gate_base_url: string
  gate_healthy: boolean | null
  gate_health_checked_at: string
  pid: number
}

export interface ConnectorBindingSummary {
  binding_source: string
  runtime_bindings_count: number
  configured_bindings_count: number
}

export interface GateConnectorInfo {
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
  reply_mode: string
  self_chat_guid: string
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
  names_path: string
  names: ConnectorNames
}

export interface GateConnectorsData {
  connectors: GateConnectorInfo[]
  total: number
  active_count: number
  generated_at: string
}

function decodeChannelInfo(raw: unknown): ChannelInfo | null {
  if (!isRecord(raw)) return null
  const channel = asString(raw.channel)
  if (!channel) return null
  return {
    channel,
    message_count: asNumber(raw.message_count, 0),
    success_count: asNumber(raw.success_count, 0),
    error_count: asNumber(raw.error_count, 0),
    duplicate_count: asNumber(raw.duplicate_count, 0),
    validation_error_count: asNumber(raw.validation_error_count, 0),
    keeper_error_count: asNumber(raw.keeper_error_count, 0),
    dispatch_unavailable_count: asNumber(raw.dispatch_unavailable_count, 0),
    internal_error_count: asNumber(raw.internal_error_count, 0),
    last_activity: asString(raw.last_activity, ''),
    last_success: asString(raw.last_success, ''),
    last_error_at: asString(raw.last_error_at, ''),
    last_keeper: asString(raw.last_keeper, ''),
    last_room_id: asString(raw.last_room_id, ''),
    last_error: asString(raw.last_error, ''),
    last_error_kind: asString(raw.last_error_kind, ''),
    last_outcome: asString(raw.last_outcome, ''),
    avg_duration_ms: asNumber(raw.avg_duration_ms, 0),
    max_duration_ms: asNumber(raw.max_duration_ms, 0),
    slow_count: asNumber(raw.slow_count, 0),
    slow_rate_pct: asNumber(raw.slow_rate_pct, 0),
    success_rate_pct: asNumber(raw.success_rate_pct, 0),
    room_count: asNumber(raw.room_count, 0),
    health: asString(raw.health, 'idle'),
  }
}

function decodeBindingInfo(raw: unknown): BindingInfo | null {
  if (!isRecord(raw)) return null
  const channel = asString(raw.channel)
  const roomId = asString(raw.room_id)
  const keeper = asString(raw.keeper)
  if (!channel || !roomId || !keeper) return null
  return {
    channel,
    room_id: roomId,
    keeper,
    message_count: asNumber(raw.message_count, 0),
    success_count: asNumber(raw.success_count, 0),
    error_count: asNumber(raw.error_count, 0),
    duplicate_count: asNumber(raw.duplicate_count, 0),
    last_activity: asString(raw.last_activity, ''),
    last_success: asString(raw.last_success, ''),
    last_error_at: asString(raw.last_error_at, ''),
    last_error: asString(raw.last_error, ''),
    last_error_kind: asString(raw.last_error_kind, ''),
    last_outcome: asString(raw.last_outcome, ''),
    avg_duration_ms: asNumber(raw.avg_duration_ms, 0),
    max_duration_ms: asNumber(raw.max_duration_ms, 0),
    success_rate_pct: asNumber(raw.success_rate_pct, 0),
    health: asString(raw.health, 'idle'),
  }
}

function decodeGateEventInfo(raw: unknown): GateEventInfo | null {
  if (!isRecord(raw)) return null
  const channel = asString(raw.channel)
  const roomId = asString(raw.room_id)
  const keeper = asString(raw.keeper)
  const timestamp = asString(raw.timestamp)
  if (!channel || !roomId || !keeper || !timestamp) return null
  return {
    seq: asNumber(raw.seq, 0),
    timestamp,
    channel,
    room_id: roomId,
    keeper,
    outcome: asString(raw.outcome, ''),
    error_kind: asString(raw.error_kind, ''),
    error: asString(raw.error, ''),
    duration_ms: asNumber(raw.duration_ms, 0),
  }
}

export function decodeGateStatusData(raw: unknown): GateStatusData | null {
  if (!isRecord(raw)) return null
  return {
    channels: asRecordArray(raw.channels)
      .map(decodeChannelInfo)
      .filter((item): item is ChannelInfo => item !== null),
    bindings: asRecordArray(raw.bindings)
      .map(decodeBindingInfo)
      .filter((item): item is BindingInfo => item !== null),
    recent_events: asRecordArray(raw.recent_events)
      .map(decodeGateEventInfo)
      .filter((item): item is GateEventInfo => item !== null),
    total_messages: asNumber(raw.total_messages, 0),
    total_success: asNumber(raw.total_success, 0),
    total_errors: asNumber(raw.total_errors, 0),
    total_duplicates: asNumber(raw.total_duplicates, 0),
    success_rate_pct: asNumber(raw.success_rate_pct, 0),
    dedup_table_size: asNumber(raw.dedup_table_size, 0),
    uptime_seconds: asNumber(raw.uptime_seconds, 0),
  }
}

function decodeGateKeeperInfo(raw: unknown): GateKeeperInfo | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    model: asString(raw.model),
    active_model: asString(raw.active_model),
    primary_model: asString(raw.primary_model),
    keepalive_running: asBoolean(raw.keepalive_running),
    last_turn_ago_s: asNumber(raw.last_turn_ago_s) ?? null,
  }
}

export function decodeGateKeepersData(raw: unknown): GateKeepersData | null {
  if (!isRecord(raw)) return null
  return {
    count: asNumber(raw.count, 0),
    keepers: asRecordArray(raw.keepers)
      .map(decodeGateKeeperInfo)
      .filter((item): item is GateKeeperInfo => item !== null),
  }
}

function decodeConfiguredBinding(raw: unknown): DiscordConfiguredBinding | null {
  if (!isRecord(raw)) return null
  const channelId = asString(raw.channel_id)
  const keeperName = asString(raw.keeper_name)
  if (!channelId || !keeperName) return null
  return {
    channel_id: channelId,
    keeper_name: keeperName,
  }
}

function decodeAuditEntry(raw: unknown): DiscordAuditEntry | null {
  if (!isRecord(raw)) return null
  const timestamp = asString(raw.timestamp)
  const action = asString(raw.action)
  const guildId = asString(raw.guild_id)
  const channelId = asString(raw.channel_id)
  const keeperName = asString(raw.keeper_name)
  const actorId = asString(raw.actor_id)
  const actorName = asString(raw.actor_name)
  if (!timestamp || !action || !guildId || !channelId || !keeperName || !actorId || !actorName) return null
  return {
    timestamp,
    action,
    guild_id: guildId,
    channel_id: channelId,
    keeper_name: keeperName,
    actor_id: actorId,
    actor_name: actorName,
    previous_keeper: asString(raw.previous_keeper, ''),
  }
}

function decodeStoragePaths(raw: unknown): ConnectorStoragePaths {
  const record = isRecord(raw) ? raw : {}
  return {
    status_path: asString(record.status_path, ''),
    binding_store_path: asString(record.binding_store_path, ''),
    audit_path: asString(record.audit_path, ''),
    names_path: asString(record.names_path, ''),
  }
}

function decodeStringMap(raw: unknown): Record<string, string> {
  if (!isRecord(raw)) return {}
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    if (typeof value === 'string' && value.length > 0) {
      out[key] = value
    }
  }
  return out
}

function decodeConnectorNames(raw: unknown): ConnectorNames {
  const record = isRecord(raw) ? raw : {}
  return {
    guild_names: decodeStringMap(record.guild_names),
    channel_names: decodeStringMap(record.channel_names),
    channel_to_guild: decodeStringMap(record.channel_to_guild),
    updated_at: asString(record.updated_at, ''),
  }
}

function decodeRuntimeSummary(raw: unknown): ConnectorRuntimeSummary {
  const record = isRecord(raw) ? raw : {}
  return {
    available: asBoolean(record.available, false),
    connected: asBoolean(record.connected, false),
    stale: asBoolean(record.stale, false),
    stale_after_sec: asNumber(record.stale_after_sec, 0),
    status: asString(record.status, ''),
    error: asString(record.error, ''),
    updated_at: asString(record.updated_at, ''),
    reply_mode: asString(record.reply_mode, ''),
    self_chat_guid: asString(record.self_chat_guid, ''),
    last_ready_at: asString(record.last_ready_at, ''),
    bot_user_name: asString(record.bot_user_name, ''),
    bot_user_id: asString(record.bot_user_id, ''),
    guild_count: asNumber(record.guild_count, 0),
    gate_base_url: asString(record.gate_base_url, ''),
    gate_healthy: asBoolean(record.gate_healthy) ?? null,
    gate_health_checked_at: asString(record.gate_health_checked_at, ''),
    pid: asNumber(record.pid, 0),
  }
}

function decodeBindingSummary(raw: unknown, configuredBindingsCount: number): ConnectorBindingSummary {
  const record = isRecord(raw) ? raw : {}
  return {
    binding_source: asString(record.binding_source, ''),
    runtime_bindings_count: asNumber(record.runtime_bindings_count, 0),
    configured_bindings_count: asNumber(record.configured_bindings_count, configuredBindingsCount),
  }
}

function decodeGateConnectorInfo(raw: unknown): GateConnectorInfo | null {
  if (!isRecord(raw)) return null
  const connectorId = asString(raw.connector_id)
  const displayName = asString(raw.display_name)
  const channel = asString(raw.channel)
  if (!connectorId || !displayName || !channel) return null

  const configuredBindings = asRecordArray(raw.configured_bindings)
    .map(decodeConfiguredBinding)
    .filter((item): item is DiscordConfiguredBinding => item !== null)
  const recentAudit = asRecordArray(raw.recent_audit)
    .map(decodeAuditEntry)
    .filter((item): item is DiscordAuditEntry => item !== null)

  return {
    connector_id: connectorId,
    display_name: displayName,
    channel,
    capabilities: asStringArray(raw.capabilities),
    status: asString(raw.status, ''),
    available: asBoolean(raw.available, false),
    connected: asBoolean(raw.connected, false),
    stale: asBoolean(raw.stale, false),
    stale_after_sec: asNumber(raw.stale_after_sec, 0),
    error: asString(raw.error, ''),
    status_path: asString(raw.status_path, ''),
    binding_store_path: asString(raw.binding_store_path, ''),
    audit_path: asString(raw.audit_path, ''),
    updated_at: asString(raw.updated_at, ''),
    reply_mode: asString(raw.reply_mode, ''),
    self_chat_guid: asString(raw.self_chat_guid, ''),
    last_ready_at: asString(raw.last_ready_at, ''),
    bot_user_name: asString(raw.bot_user_name, ''),
    bot_user_id: asString(raw.bot_user_id, ''),
    guild_count: asNumber(raw.guild_count, 0),
    gate_base_url: asString(raw.gate_base_url, ''),
    gate_healthy: asBoolean(raw.gate_healthy) ?? null,
    gate_health_checked_at: asString(raw.gate_health_checked_at, ''),
    binding_source: asString(raw.binding_source, ''),
    runtime_bindings_count: asNumber(raw.runtime_bindings_count, 0),
    pid: asNumber(raw.pid, 0),
    configured_bindings: configuredBindings,
    recent_audit: recentAudit,
    storage_paths: decodeStoragePaths(raw.storage_paths),
    runtime_summary: decodeRuntimeSummary(raw.runtime_summary),
    binding_summary: decodeBindingSummary(raw.binding_summary, configuredBindings.length),
    observed_channel: decodeChannelInfo(raw.observed_channel) ?? null,
    names_path: asString(raw.names_path, ''),
    names: decodeConnectorNames(raw.names),
  }
}

export function decodeGateConnectorsData(raw: unknown): GateConnectorsData | null {
  if (!isRecord(raw)) return null
  const generatedAt = asString(raw.generated_at)
  if (!generatedAt) return null
  return {
    connectors: asRecordArray(raw.connectors)
      .map(decodeGateConnectorInfo)
      .filter((item): item is GateConnectorInfo => item !== null),
    total: asNumber(raw.total, 0),
    active_count: asNumber(raw.active_count, 0),
    generated_at: generatedAt,
  }
}

export async function fetchGateStatus(signal?: AbortSignal): Promise<GateStatusData> {
  const raw = await get<Record<string, unknown>>('/api/v1/gate/status', { signal })
  const decoded = decodeGateStatusData(raw)
  if (!decoded) throw new Error('invalid gate status payload')
  return decoded
}

export async function fetchGateConnectors(signal?: AbortSignal): Promise<GateConnectorsData> {
  const raw = await get<Record<string, unknown>>('/api/v1/gate/connectors', { signal })
  const decoded = decodeGateConnectorsData(raw)
  if (!decoded) throw new Error('invalid gate connectors payload')
  return decoded
}

export async function fetchGateKeepers(signal?: AbortSignal): Promise<GateKeepersData> {
  const raw = await get<Record<string, unknown>>('/api/v1/gate/keepers?limit=50&detailed=true', { signal })
  const decoded = decodeGateKeepersData(raw)
  if (!decoded) throw new Error('invalid gate keepers payload')
  return decoded
}


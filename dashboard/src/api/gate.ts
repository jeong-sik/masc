import { get } from './core'
import {
  asBoolean,
  asNumber,
  asRecordArray,
  asString,
  asStringArray,
  isRecord,
} from '../components/common/normalize'
import {
  parseGateStatusData,
  safeParseChannelInfo,
  type BindingInfo,
  type ChannelInfo,
  type GateEventInfo,
  type GateStatusData,
} from './schemas/gate-status'

export type { BindingInfo, ChannelInfo, GateEventInfo, GateStatusData }
export { GateStatusSchemaDriftError } from './schemas/gate-status'

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

// Thin null-returning wrappers preserving the pre-migration contract.
// `src/api/gate.test.ts` still asserts `null` on non-object payloads,
// and `decodeGateConnectorInfo` (the sibling connector decoder that
// this PR intentionally does not touch) consumes single-channel
// payloads via `decodeChannelInfo`. New call sites should use the
// throw-on-drift parsers directly.
export function decodeGateStatusData(raw: unknown): GateStatusData | null {
  try {
    return parseGateStatusData(raw)
  } catch {
    return null
  }
}

function decodeChannelInfo(raw: unknown): ChannelInfo | null {
  const result = safeParseChannelInfo(raw)
  return result.success ? result.output : null
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
  const raw = await get<unknown>('/api/v1/gate/status', { signal })
  return parseGateStatusData(raw)
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


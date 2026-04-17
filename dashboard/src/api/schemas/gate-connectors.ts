// Gate connectors schema — schema-at-boundary for
// `GET /api/v1/gate/connectors`.
//
// Largest connector-describing endpoint on the dashboard: 5 nested
// object shapes + 2 arrays + 1 optional observed-channel. Each string
// field falls back to `''` and each number to `0` (matches the prior
// `asString(raw.X, '')` / `asNumber(raw.X, 0)` defaulting). Three
// nested decoders (storage_paths / connector_names / runtime_summary)
// are guaranteed to return a shaped object even when the input is
// entirely missing — we preserve that "never null, always a record"
// contract via `fallback(schema, {...})`.
//
// `binding_summary.configured_bindings_count` has a cross-field
// default: the prior decoder passed `configuredBindings.length` as the
// fallback. Preserved via a post-parse transform.
//
// `connectors[].observed_channel` delegates to
// `schemas/gate-status.ts` (same `ChannelInfo` shape). Lenient
// per-entry is maintained for the connectors list itself.
//
// Uses the shared `SchemaDriftError` base landed in #7732.

import {
  array,
  boolean,
  check,
  fallback,
  nullable,
  number,
  object,
  optional,
  pipe,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'
import { safeParseChannelInfo, type ChannelInfo } from './gate-status'

// --- Nested schemas ---

const DiscordConfiguredBindingSchema = object({
  channel_id: string(),
  keeper_name: string(),
})

export type DiscordConfiguredBinding = InferOutput<typeof DiscordConfiguredBindingSchema>

const DiscordAuditEntrySchema = object({
  timestamp: string(),
  action: string(),
  guild_id: string(),
  channel_id: string(),
  keeper_name: string(),
  actor_id: string(),
  actor_name: string(),
  previous_keeper: fallback(string(), ''),
})

export type DiscordAuditEntry = InferOutput<typeof DiscordAuditEntrySchema>

// Nested decoders below used `const record = isRecord(raw) ? raw : {}`
// — i.e. they always returned a shaped object. `fallback(object({...}),
// {...})` reproduces that exactly: missing or wrong-typed input yields
// the default shape instead of drift.

const DEFAULT_STORAGE_PATHS = {
  status_path: '',
  binding_store_path: '',
  audit_path: '',
  names_path: '',
} as const

const ConnectorStoragePathsSchema = fallback(
  object({
    status_path: fallback(string(), ''),
    binding_store_path: fallback(string(), ''),
    audit_path: fallback(string(), ''),
    names_path: fallback(string(), ''),
  }),
  { ...DEFAULT_STORAGE_PATHS },
)

export type ConnectorStoragePaths = InferOutput<typeof ConnectorStoragePathsSchema>

// The prior `decodeStringMap` dropped entries whose value was not a
// non-empty string. Valibot's `record(string, string())` would accept
// any string (including '') and fail on non-string values; a transform
// over an open record replicates the filter semantics.
const filteredStringMap = () => ({
  parse: (raw: unknown): Record<string, string> => {
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return {}
    const out: Record<string, string> = {}
    for (const [key, value] of Object.entries(raw)) {
      if (typeof value === 'string' && value.length > 0) {
        out[key] = value
      }
    }
    return out
  },
})

const ConnectorNamesSchema = object({
  guild_names: optional(unknown()),
  channel_names: optional(unknown()),
  channel_to_guild: optional(unknown()),
  updated_at: fallback(string(), ''),
})

export interface ConnectorNames {
  guild_names: Record<string, string>
  channel_names: Record<string, string>
  channel_to_guild: Record<string, string>
  updated_at: string
}

function parseConnectorNames(raw: unknown): ConnectorNames {
  const outer = safeParse(ConnectorNamesSchema, raw, { abortEarly: true })
  const defaults: ConnectorNames = {
    guild_names: {},
    channel_names: {},
    channel_to_guild: {},
    updated_at: '',
  }
  if (!outer.success) return defaults
  const filter = filteredStringMap().parse
  return {
    guild_names: filter(outer.output.guild_names),
    channel_names: filter(outer.output.channel_names),
    channel_to_guild: filter(outer.output.channel_to_guild),
    updated_at: outer.output.updated_at,
  }
}

const ConnectorRuntimeSummarySchema = object({
  available: fallback(boolean(), false),
  connected: fallback(boolean(), false),
  stale: fallback(boolean(), false),
  stale_after_sec: fallback(number(), 0),
  status: fallback(string(), ''),
  error: fallback(string(), ''),
  updated_at: fallback(string(), ''),
  reply_mode: fallback(string(), ''),
  self_chat_guid: fallback(string(), ''),
  last_ready_at: fallback(string(), ''),
  bot_user_name: fallback(string(), ''),
  bot_user_id: fallback(string(), ''),
  guild_count: fallback(number(), 0),
  gate_base_url: fallback(string(), ''),
  // `asBoolean(x) ?? null` — absent/undefined → null, not undefined.
  gate_healthy: fallback(nullable(boolean()), null),
  gate_health_checked_at: fallback(string(), ''),
  pid: fallback(number(), 0),
})

export type ConnectorRuntimeSummary = InferOutput<typeof ConnectorRuntimeSummarySchema>

const DEFAULT_RUNTIME_SUMMARY: ConnectorRuntimeSummary = {
  available: false,
  connected: false,
  stale: false,
  stale_after_sec: 0,
  status: '',
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
}

const ConnectorBindingSummarySchema = object({
  binding_source: fallback(string(), ''),
  runtime_bindings_count: fallback(number(), 0),
  // `configured_bindings_count` falls back to `configuredBindings.length`
  // at the connector level, not here. A placeholder `0` is used as the
  // inner default; the connector transform fills the real value.
  configured_bindings_count: fallback(number(), 0),
})

export type ConnectorBindingSummary = InferOutput<typeof ConnectorBindingSummarySchema>

// --- Connector info ---

const GateConnectorInfoRawSchema = object({
  connector_id: string(),
  display_name: string(),
  channel: string(),
  capabilities: fallback(array(string()), []),
  status: fallback(string(), ''),
  available: fallback(boolean(), false),
  connected: fallback(boolean(), false),
  stale: fallback(boolean(), false),
  stale_after_sec: fallback(number(), 0),
  error: fallback(string(), ''),
  status_path: fallback(string(), ''),
  binding_store_path: fallback(string(), ''),
  audit_path: fallback(string(), ''),
  updated_at: fallback(string(), ''),
  reply_mode: fallback(string(), ''),
  self_chat_guid: fallback(string(), ''),
  last_ready_at: fallback(string(), ''),
  bot_user_name: fallback(string(), ''),
  bot_user_id: fallback(string(), ''),
  guild_count: fallback(number(), 0),
  gate_base_url: fallback(string(), ''),
  gate_healthy: fallback(nullable(boolean()), null),
  gate_health_checked_at: fallback(string(), ''),
  binding_source: fallback(string(), ''),
  runtime_bindings_count: fallback(number(), 0),
  pid: fallback(number(), 0),
  configured_bindings: optional(unknown()),
  recent_audit: optional(unknown()),
  storage_paths: optional(unknown()),
  runtime_summary: optional(unknown()),
  binding_summary: optional(unknown()),
  observed_channel: optional(unknown()),
  names_path: fallback(string(), ''),
  names: optional(unknown()),
})

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

function parseConnectorsArray<TSchema extends typeof DiscordConfiguredBindingSchema
  | typeof DiscordAuditEntrySchema>(
  schema: TSchema,
  raw: unknown,
): InferOutput<TSchema>[] {
  if (!Array.isArray(raw)) return []
  const out: InferOutput<TSchema>[] = []
  for (const item of raw) {
    const parsed = safeParse(schema, item, { abortEarly: true })
    if (parsed.success) out.push(parsed.output as InferOutput<TSchema>)
  }
  return out
}

function parseRuntimeSummary(raw: unknown): ConnectorRuntimeSummary {
  const parsed = safeParse(ConnectorRuntimeSummarySchema, raw, { abortEarly: true })
  return parsed.success ? parsed.output : { ...DEFAULT_RUNTIME_SUMMARY }
}

function parseBindingSummary(raw: unknown, configuredBindingsCount: number): ConnectorBindingSummary {
  const parsed = safeParse(ConnectorBindingSummarySchema, raw, { abortEarly: true })
  if (!parsed.success) {
    return {
      binding_source: '',
      runtime_bindings_count: 0,
      configured_bindings_count: configuredBindingsCount,
    }
  }
  // Cross-field default preserved: if the backend omitted
  // configured_bindings_count, fall back to the decoded array length.
  const hasField = raw !== null && typeof raw === 'object' && !Array.isArray(raw)
    && typeof (raw as Record<string, unknown>).configured_bindings_count === 'number'
  return {
    ...parsed.output,
    configured_bindings_count: hasField
      ? parsed.output.configured_bindings_count
      : configuredBindingsCount,
  }
}

function parseObservedChannel(raw: unknown): ChannelInfo | null {
  if (raw === undefined || raw === null) return null
  const parsed = safeParseChannelInfo(raw)
  return parsed.success ? parsed.output : null
}

function parseGateConnectorInfo(raw: unknown): GateConnectorInfo | null {
  const outer = safeParse(GateConnectorInfoRawSchema, raw, { abortEarly: true })
  if (!outer.success) return null

  const configured_bindings = parseConnectorsArray(
    DiscordConfiguredBindingSchema,
    outer.output.configured_bindings,
  )
  const recent_audit = parseConnectorsArray(
    DiscordAuditEntrySchema,
    outer.output.recent_audit,
  )

  return {
    connector_id: outer.output.connector_id,
    display_name: outer.output.display_name,
    channel: outer.output.channel,
    capabilities: outer.output.capabilities,
    status: outer.output.status,
    available: outer.output.available,
    connected: outer.output.connected,
    stale: outer.output.stale,
    stale_after_sec: outer.output.stale_after_sec,
    error: outer.output.error,
    status_path: outer.output.status_path,
    binding_store_path: outer.output.binding_store_path,
    audit_path: outer.output.audit_path,
    updated_at: outer.output.updated_at,
    reply_mode: outer.output.reply_mode,
    self_chat_guid: outer.output.self_chat_guid,
    last_ready_at: outer.output.last_ready_at,
    bot_user_name: outer.output.bot_user_name,
    bot_user_id: outer.output.bot_user_id,
    guild_count: outer.output.guild_count,
    gate_base_url: outer.output.gate_base_url,
    gate_healthy: outer.output.gate_healthy,
    gate_health_checked_at: outer.output.gate_health_checked_at,
    binding_source: outer.output.binding_source,
    runtime_bindings_count: outer.output.runtime_bindings_count,
    pid: outer.output.pid,
    configured_bindings,
    recent_audit,
    storage_paths: parseStoragePaths(outer.output.storage_paths),
    runtime_summary: parseRuntimeSummary(outer.output.runtime_summary),
    binding_summary: parseBindingSummary(
      outer.output.binding_summary,
      configured_bindings.length,
    ),
    observed_channel: parseObservedChannel(outer.output.observed_channel),
    names_path: outer.output.names_path,
    names: parseConnectorNames(outer.output.names),
  }
}

function parseStoragePaths(raw: unknown): ConnectorStoragePaths {
  const parsed = safeParse(ConnectorStoragePathsSchema, raw, { abortEarly: true })
  return parsed.success ? parsed.output : { ...DEFAULT_STORAGE_PATHS }
}

// --- Outer shape ---

const GateConnectorsOuterSchema = object({
  connectors: optional(unknown()),
  total: fallback(number(), 0),
  active_count: fallback(number(), 0),
  // Empty string is treated as drift — matches prior decoder's
  // `if (!generatedAt) return null` guard. A connectors payload
  // without a timestamp is not a useful one; the null-returning
  // wrapper in api/gate.ts surfaces this as null.
  generated_at: pipe(string(), check(s => s.length > 0, 'generated_at must be non-empty')),
})

export interface GateConnectorsData {
  connectors: GateConnectorInfo[]
  total: number
  active_count: number
  generated_at: string
}

export class GateConnectorsSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('gate-connectors', issues)
  }
}

export function parseGateConnectorsData(data: unknown): GateConnectorsData {
  const outer = parseOrThrow(
    GateConnectorsSchemaDriftError,
    GateConnectorsOuterSchema,
    data,
  )
  const rawEntries = Array.isArray(outer.connectors) ? outer.connectors : []
  const connectors: GateConnectorInfo[] = []
  for (const raw of rawEntries) {
    const parsed = parseGateConnectorInfo(raw)
    if (parsed !== null) connectors.push(parsed)
  }
  return {
    connectors,
    total: outer.total,
    active_count: outer.active_count,
    generated_at: outer.generated_at,
  }
}

// Re-export helper for the `ChannelInfo` dependency to keep the public
// surface of this module cohesive.
export type { ChannelInfo }

// Gate connectors schema — schema-at-boundary for
// `GET /api/v1/gate/connectors`.
//
// Each string field falls back to `''` and each number to `0` (matches the
// prior `asString(raw.X, '')` / `asNumber(raw.X, 0)` defaulting). Lenient
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

// --- Connector info ---

const GateConnectorInfoRawSchema = object({
  connector_id: string(),
  display_name: string(),
  channel: string(),
  capabilities: fallback(array(string()), []),
  trigger_policy: optional(nullable(string()), null),
  status: fallback(string(), ''),
  available: fallback(boolean(), false),
  connected: fallback(boolean(), false),
  stale: fallback(boolean(), false),
  stale_after_sec: fallback(number(), 0),
  // In-process gateway machine state (RFC-0203 / #20813): disconnected /
  // awaiting_hello / identifying / resuming / connected /
  // reconnect_pending / failed. Empty means "not advertised".
  gateway_state: fallback(string(), ''),
  // 'in_process_gateway' for connectors whose status comes from the
  // typed gateway state machine; empty when the server did not send it.
  status_source: fallback(string(), ''),
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
})

export interface GateConnectorInfo {
  connector_id: string
  display_name: string
  channel: string
  capabilities: string[]
  trigger_policy: string | null
  status: string
  available: boolean
  connected: boolean
  stale: boolean
  stale_after_sec: number
  gateway_state: string
  status_source: string
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
    trigger_policy: outer.output.trigger_policy,
    status: outer.output.status,
    available: outer.output.available,
    connected: outer.output.connected,
    stale: outer.output.stale,
    stale_after_sec: outer.output.stale_after_sec,
    gateway_state: outer.output.gateway_state,
    status_source: outer.output.status_source,
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
  }
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

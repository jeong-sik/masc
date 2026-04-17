// Gate status schema — schema-at-boundary for
// `GET /api/v1/gate/status`.
//
// Every number field carries `fallback(number(), 0)` and every string
// field carries `fallback(string(), '')` (or `'idle'` for the health
// flag) to match the prior hand-rolled `asString(raw.X, '')` /
// `asNumber(raw.X, 0)` decoder semantics exactly.
//
// Per-entry leniency is preserved: a channel/binding/event row with
// a missing required field drops silently from the array, while the
// outer payload must still be a record (else throws).

import {
  fallback,
  number,
  object,
  optional,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

const ChannelInfoRawSchema = object({
  channel: string(),
  message_count: fallback(number(), 0),
  success_count: fallback(number(), 0),
  error_count: fallback(number(), 0),
  duplicate_count: fallback(number(), 0),
  validation_error_count: fallback(number(), 0),
  keeper_error_count: fallback(number(), 0),
  dispatch_unavailable_count: fallback(number(), 0),
  internal_error_count: fallback(number(), 0),
  last_activity: fallback(string(), ''),
  last_success: fallback(string(), ''),
  last_error_at: fallback(string(), ''),
  last_keeper: fallback(string(), ''),
  last_room_id: fallback(string(), ''),
  last_error: fallback(string(), ''),
  last_error_kind: fallback(string(), ''),
  last_outcome: fallback(string(), ''),
  avg_duration_ms: fallback(number(), 0),
  max_duration_ms: fallback(number(), 0),
  slow_count: fallback(number(), 0),
  slow_rate_pct: fallback(number(), 0),
  success_rate_pct: fallback(number(), 0),
  room_count: fallback(number(), 0),
  health: fallback(string(), 'idle'),
})

export type ChannelInfo = InferOutput<typeof ChannelInfoRawSchema>

const BindingInfoRawSchema = object({
  channel: string(),
  room_id: string(),
  keeper: string(),
  message_count: fallback(number(), 0),
  success_count: fallback(number(), 0),
  error_count: fallback(number(), 0),
  duplicate_count: fallback(number(), 0),
  last_activity: fallback(string(), ''),
  last_success: fallback(string(), ''),
  last_error_at: fallback(string(), ''),
  last_error: fallback(string(), ''),
  last_error_kind: fallback(string(), ''),
  last_outcome: fallback(string(), ''),
  avg_duration_ms: fallback(number(), 0),
  max_duration_ms: fallback(number(), 0),
  success_rate_pct: fallback(number(), 0),
  health: fallback(string(), 'idle'),
})

export type BindingInfo = InferOutput<typeof BindingInfoRawSchema>

const GateEventInfoRawSchema = object({
  seq: fallback(number(), 0),
  timestamp: string(),
  channel: string(),
  room_id: string(),
  keeper: string(),
  outcome: fallback(string(), ''),
  error_kind: fallback(string(), ''),
  error: fallback(string(), ''),
  duration_ms: fallback(number(), 0),
})

export type GateEventInfo = InferOutput<typeof GateEventInfoRawSchema>

const GateStatusOuterSchema = object({
  channels: optional(unknown()),
  bindings: optional(unknown()),
  recent_events: optional(unknown()),
  total_messages: fallback(number(), 0),
  total_success: fallback(number(), 0),
  total_errors: fallback(number(), 0),
  total_duplicates: fallback(number(), 0),
  success_rate_pct: fallback(number(), 0),
  dedup_table_size: fallback(number(), 0),
  uptime_seconds: fallback(number(), 0),
})

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

export class GateStatusSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`gate-status schema drift: ${summary}`)
    this.name = GateStatusSchemaDriftError.name
    this.issues = issues
  }
}

function parseArrayOfEntries<TSchema extends typeof ChannelInfoRawSchema
  | typeof BindingInfoRawSchema
  | typeof GateEventInfoRawSchema>(
  schema: TSchema,
  raw: unknown,
): InferOutput<TSchema>[] {
  if (!Array.isArray(raw)) return []
  const result: InferOutput<TSchema>[] = []
  for (const item of raw) {
    const parsed = safeParse(schema, item, { abortEarly: true })
    if (parsed.success) result.push(parsed.output as InferOutput<TSchema>)
  }
  return result
}

// Exposed for `api/gate.ts`'s sibling connector decoder, which still
// consumes a single channel payload through a null-returning wrapper.
export function safeParseChannelInfo(data: unknown) {
  return safeParse(ChannelInfoRawSchema, data, { abortEarly: true })
}

export function parseGateStatusData(data: unknown): GateStatusData {
  const outer = safeParse(GateStatusOuterSchema, data, { abortEarly: true })
  if (!outer.success) {
    throw new GateStatusSchemaDriftError(outer.issues)
  }
  return {
    channels: parseArrayOfEntries(ChannelInfoRawSchema, outer.output.channels),
    bindings: parseArrayOfEntries(BindingInfoRawSchema, outer.output.bindings),
    recent_events: parseArrayOfEntries(GateEventInfoRawSchema, outer.output.recent_events),
    total_messages: outer.output.total_messages,
    total_success: outer.output.total_success,
    total_errors: outer.output.total_errors,
    total_duplicates: outer.output.total_duplicates,
    success_rate_pct: outer.output.success_rate_pct,
    dedup_table_size: outer.output.dedup_table_size,
    uptime_seconds: outer.output.uptime_seconds,
  }
}

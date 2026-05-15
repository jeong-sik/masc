// System logs schema — schema-at-boundary for
// `GET /api/v1/dashboard/logs`.
//
// RFC-0079: the backend now writes the wire format through a typed
// encoder (`lib/masc_log/log.ml` `Ring.entry_to_json`). Every row carries
// a valid `level` / `source` string from a closed sum on the producer
// side, so the read-side no longer fabricates fallbacks or counts
// silently-dropped rows. Per-entry validation failure is a strict
// schema-drift error — it surfaces the producer/consumer mismatch
// instead of hiding it behind a `dropped_entries` counter.
//
// The pre-RFC-0079 fields `raw_level` / `normalized_level` /
// `legacy_classified` are gone with the typed encoder: they only ever
// reflected the backend's string-prefix classifier, which has been
// removed.

import {
  nullable,
  number,
  object,
  optional,
  record,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

const LogEntrySchema = object({
  seq: number(),
  ts: string(),
  level: string(),
  source: string(),
  module: string(),
  message: string(),
  keeper_name: optional(nullable(string())),
  turn_id: optional(nullable(number())),
  details: optional(nullable(record(string(), unknown()))),
})

export type LogEntry = InferOutput<typeof LogEntrySchema>

const LogsResponseSchema = object({
  total: number(),
  entries: unknown(),
  generated_at_iso: optional(string()),
  dashboard_surface: optional(string()),
  source: optional(string()),
  retention: optional(record(string(), unknown())),
  query: optional(record(string(), unknown())),
  returned: optional(number()),
  latest_seq: optional(nullable(number())),
  oldest_seq: optional(nullable(number())),
  latest_ts_iso: optional(nullable(string())),
})

export interface LogsRetention {
  scope?: string
  coordination_root?: string
  buffer?: string
  capacity?: number
  durable_store?: string
  file_pattern?: string
  keep_days?: number
  cache_policy?: string
}

export interface LogsQuery {
  limit?: number
  level?: string
  applied_level?: string
  min_level?: number
  module?: string
  since_seq?: number | null
}

export interface LogsResponse {
  total: number
  entries: LogEntry[]
  generated_at_iso?: string
  dashboard_surface?: string
  source?: string
  retention?: LogsRetention
  query?: LogsQuery
  returned?: number
  latest_seq?: number | null
  oldest_seq?: number | null
  latest_ts_iso?: string | null
}

export class LogsSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`logs schema drift: ${summary}`)
    this.name = LogsSchemaDriftError.name
    this.issues = issues
  }
}

export function parseLogsResponse(data: unknown): LogsResponse {
  const outer = safeParse(LogsResponseSchema, data, { abortEarly: true })
  if (!outer.success) {
    throw new LogsSchemaDriftError(outer.issues)
  }
  const rawEntries = Array.isArray(outer.output.entries) ? outer.output.entries : []
  const entries: LogEntry[] = []
  for (const raw of rawEntries) {
    const parsed = safeParse(LogEntrySchema, raw, { abortEarly: true })
    if (!parsed.success) {
      throw new LogsSchemaDriftError(parsed.issues)
    }
    entries.push(parsed.output)
  }
  return {
    total: outer.output.total,
    entries,
    generated_at_iso: outer.output.generated_at_iso,
    dashboard_surface: outer.output.dashboard_surface,
    source: outer.output.source,
    retention: outer.output.retention as LogsRetention | undefined,
    query: outer.output.query as LogsQuery | undefined,
    returned: outer.output.returned,
    latest_seq: outer.output.latest_seq,
    oldest_seq: outer.output.oldest_seq,
    latest_ts_iso: outer.output.latest_ts_iso,
  }
}

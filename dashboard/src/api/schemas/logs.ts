// System logs schema — schema-at-boundary for
// `GET /api/v1/dashboard/logs`.
//
// `level` / `source` / `module` / `legacy_classified` carry `fallback`
// defaults that match the prior hand-rolled decoder (`decodeLogEntry`).
// Individual entries that fail validation are dropped from the array
// (not thrown) to preserve the original lenient-per-entry behavior —
// one corrupt log row should never blank the entire logs panel.
//
// The outer response shape is strict: if the top-level `entries` field
// is missing or the payload is not an object, the parser throws
// `LogsSchemaDriftError`.

import {
  boolean,
  fallback,
  nullable,
  number,
  object,
  optional,
  pipe,
  record,
  safeParse,
  string,
  transform,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

// Individual entry schema. `raw_level` and `normalized_level` stay
// `optional` here so the transform below can chain them to `level` —
// reproducing the original decoder's chained-default semantic exactly.
const LogEntryRawSchema = object({
  seq: number(),
  ts: string(),
  level: fallback(string(), 'INFO'),
  raw_level: optional(string()),
  normalized_level: optional(string()),
  source: fallback(string(), 'structured'),
  legacy_classified: fallback(boolean(), false),
  module: fallback(string(), ''),
  message: string(),
  details: optional(nullable(record(string(), unknown()))),
})

const LogEntrySchema = pipe(
  LogEntryRawSchema,
  transform(entry => ({
    ...entry,
    raw_level: entry.raw_level ?? entry.level,
    normalized_level: entry.normalized_level ?? entry.level,
    details: entry.details ?? null,
  })),
)

export type LogEntry = InferOutput<typeof LogEntrySchema>

const LogsResponseSchema = object({
  total: fallback(number(), 0),
  entries: unknown(),
})

// The exported `LogsResponse` type uses the post-filter entries array.
export interface LogsResponse {
  total: number
  entries: LogEntry[]
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
    if (parsed.success) entries.push(parsed.output)
  }
  return { total: outer.output.total, entries }
}

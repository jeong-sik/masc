import { Data, Effect, Option, ParseResult, Schema } from 'effect'

const LogLevelSchema = Schema.Literal('DEBUG', 'INFO', 'WARN', 'ERROR')
const LogSourceSchema = Schema.Literal(
  'structured',
  'legacy_stderr',
  'legacy_traceln',
  'client_tool_host',
)
const LogCategorySchema = Schema.Literal(
  'fsm',
  'lifecycle',
  'directive',
  'heartbeat',
  'tool',
  'routine',
  'boundary',
  'turn',
  'broadcast',
)

const LogDetailsSchema = Schema.Record({
  key: Schema.String,
  value: Schema.Unknown,
})

const LogEntryWireSchema = Schema.Struct({
  seq: Schema.NonNegativeInt,
  ts: Schema.NonEmptyString,
  level: LogLevelSchema,
  source: LogSourceSchema,
  module: Schema.String,
  keeper_name: Schema.NonEmptyString,
  turn_id: Schema.OptionFromNullOr(Schema.NonNegativeInt),
  message: Schema.String,
  details: Schema.OptionFromNullOr(LogDetailsSchema),
  category: Schema.OptionFromNullOr(LogCategorySchema),
})

const LogsRetentionWireSchema = Schema.Struct({
  scope: Schema.Literal('dashboard_logs'),
  workspace_root: Schema.NonEmptyString,
  buffer: Schema.Literal('Log.Ring'),
  capacity: Schema.NonNegativeInt,
  durable_store: Schema.NonEmptyString,
  file_pattern: Schema.Literal('system_log_YYYY-MM-DD.jsonl'),
  keep_days: Schema.NonNegativeInt,
  cache_policy: Schema.NonEmptyString,
})

const LogsQueryWireSchema = Schema.Struct({
  limit: Schema.NonNegativeInt,
  level: Schema.String,
  applied_level: LogLevelSchema,
  min_level: Schema.NonNegativeInt,
  module: Schema.String,
  since_seq: Schema.OptionFromNullOr(Schema.NonNegativeInt),
  before_seq: Schema.OptionFromNullOr(Schema.NonNegativeInt),
  category: Schema.OptionFromNullOr(LogCategorySchema),
  exclude_category: Schema.OptionFromNullOr(Schema.Array(LogCategorySchema)),
})

// Live-window bounds of the log ring (server #29011). `dropped_before` true
// means entries below `start_seq` have already left the ring, so a thin or
// empty result there is "outside the window — consult retention.durable_store",
// not "did not happen".
const LogsRingWireSchema = Schema.Struct({
  start_seq: Schema.NonNegativeInt,
  total: Schema.NonNegativeInt,
  dropped_before: Schema.Boolean,
})

const LogsWireSchema = Schema.Struct({
  generated_at_iso: Schema.NonEmptyString,
  dashboard_surface: Schema.Literal('/api/v1/dashboard/logs'),
  source: Schema.Literal('masc_log_ring'),
  retention: LogsRetentionWireSchema,
  query: LogsQueryWireSchema,
  returned: Schema.NonNegativeInt,
  ring: LogsRingWireSchema,
  latest_seq: Schema.OptionFromNullOr(Schema.NonNegativeInt),
  oldest_seq: Schema.OptionFromNullOr(Schema.NonNegativeInt),
  latest_ts_iso: Schema.OptionFromNullOr(Schema.NonEmptyString),
  total: Schema.NonNegativeInt,
  entries: Schema.Array(LogEntryWireSchema),
})

type LogsWire = Schema.Schema.Type<typeof LogsWireSchema>
type LogEntryWire = Schema.Schema.Type<typeof LogEntryWireSchema>

function logsInvariantIssues(data: LogsWire) {
  const issues: Array<{
    readonly path: ReadonlyArray<PropertyKey>
    readonly message: string
  }> = []
  const newest = data.entries[0]
  const oldest = data.entries[data.entries.length - 1]
  const latestSeq = Option.getOrUndefined(data.latest_seq)
  const oldestSeq = Option.getOrUndefined(data.oldest_seq)
  const latestTimestamp = Option.getOrUndefined(data.latest_ts_iso)

  if (data.returned !== data.entries.length) {
    issues.push({
      path: ['returned'],
      message: 'must equal entries.length',
    })
  }
  if (data.total < data.returned) {
    issues.push({
      path: ['total'],
      message: 'must be greater than or equal to returned',
    })
  }
  if (data.query.limit < data.returned) {
    issues.push({
      path: ['query', 'limit'],
      message: 'must be greater than or equal to returned',
    })
  }
  if (latestSeq !== newest?.seq) {
    issues.push({
      path: ['latest_seq'],
      message: 'must equal the newest entry seq, or null when entries is empty',
    })
  }
  if (oldestSeq !== oldest?.seq) {
    issues.push({
      path: ['oldest_seq'],
      message: 'must equal the oldest entry seq, or null when entries is empty',
    })
  }
  if (latestTimestamp !== newest?.ts) {
    issues.push({
      path: ['latest_ts_iso'],
      message: 'must equal the newest entry timestamp, or null when entries is empty',
    })
  }
  if (data.entries.some((entry, index) => {
    const next = data.entries[index + 1]
    return next !== undefined && entry.seq <= next.seq
  })) {
    issues.push({
      path: ['entries'],
      message: 'must be strictly newest-seq-first',
    })
  }

  return issues
}

const LogsValidatedWireSchema = LogsWireSchema.pipe(
  Schema.filter(logsInvariantIssues),
)

export type LogLevel = Schema.Schema.Type<typeof LogLevelSchema>
export type LogSource = Schema.Schema.Type<typeof LogSourceSchema>
export type LogCategory = Schema.Schema.Type<typeof LogCategorySchema>

export interface LogEntry {
  readonly seq: number
  readonly timestamp: string
  readonly level: LogLevel
  readonly source: LogSource
  readonly module: string
  readonly keeperName: string
  readonly hasTurn: boolean
  readonly message: string
  readonly details: Readonly<Record<string, unknown>>
  /** The producer's typed category; null when the OCaml emit carried none. */
  readonly category: LogCategory | null
}

export interface LogsData {
  readonly generatedAt: string
  readonly source: 'masc_log_ring'
  readonly retention: {
    readonly scope: 'dashboard_logs'
    readonly durableStore: string
  }
  readonly ring: {
    readonly startSeq: number
    readonly total: number
    readonly droppedBefore: boolean
  }
  readonly total: number
  readonly entries: readonly LogEntry[]
}

export class LogsSchemaDriftError extends Data.TaggedError(
  'LogsSchemaDriftError',
)<{
  readonly domain: 'logs'
  readonly issues: ReadonlyArray<ParseResult.ArrayFormatterIssue>
  readonly message: string
}> {}

function schemaDriftError(error: ParseResult.ParseError): LogsSchemaDriftError {
  const issues = ParseResult.ArrayFormatter.formatErrorSync(error)
  const details = issues
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return new LogsSchemaDriftError({
    domain: 'logs',
    issues,
    message: `logs schema drift: ${details}`,
  })
}

const EMPTY_LOG_DETAILS: Readonly<Record<string, unknown>> = Object.freeze({})

function toLogEntry(wire: LogEntryWire): LogEntry {
  return {
    seq: wire.seq,
    timestamp: wire.ts,
    level: wire.level,
    source: wire.source,
    module: wire.module,
    keeperName: wire.keeper_name,
    hasTurn: Option.isSome(wire.turn_id),
    message: wire.message,
    details: Option.getOrElse(wire.details, () => EMPTY_LOG_DETAILS),
    category: Option.getOrNull(wire.category),
  }
}

function toLogsData(wire: LogsWire): LogsData {
  return {
    generatedAt: wire.generated_at_iso,
    source: wire.source,
    retention: {
      scope: wire.retention.scope,
      durableStore: wire.retention.durable_store,
    },
    ring: {
      startSeq: wire.ring.start_seq,
      total: wire.ring.total,
      droppedBefore: wire.ring.dropped_before,
    },
    total: wire.total,
    entries: wire.entries.map(toLogEntry),
  }
}

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function decodeLogsData(
  data: unknown,
): Effect.Effect<LogsData, LogsSchemaDriftError> {
  return Schema.decodeUnknown(
    LogsValidatedWireSchema,
    STRICT_PARSE_OPTIONS,
  )(data).pipe(
    Effect.map(toLogsData),
    Effect.mapError(schemaDriftError),
  )
}

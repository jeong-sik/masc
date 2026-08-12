import { Data, Effect, ParseResult, Schema } from 'effect'

const KeeperMetaWireSchema = Schema.Struct({
  name: Schema.NonEmptyString,
  trace_id: Schema.NonEmptyString,
  created_at: Schema.NonEmptyString,
  updated_at: Schema.NonEmptyString,
})

const GateKeeperWireSchema = Schema.Struct({
  runtime_class: Schema.Literal('keeper'),
  name: Schema.NonEmptyString,
  meta: KeeperMetaWireSchema,
  agent_name: Schema.NonEmptyString,
  status: Schema.NonEmptyString,
  keepalive_running: Schema.Boolean,
  autoboot_enabled: Schema.Boolean,
  proactive_enabled: Schema.Boolean,
  runtime_id: Schema.NonEmptyString,
  created_at: Schema.NonEmptyString,
  updated_at: Schema.NonEmptyString,
})

const GateKeeperDirectoryIssueWireSchema = Schema.Struct({
  keeper: Schema.NonEmptyString,
  message: Schema.NonEmptyString,
  terminal_reason: Schema.Literal('effective_meta_read_failed'),
  severity: Schema.Literal('error'),
  operator_action_required: Schema.Literal(true),
  next_action: Schema.Literal('fix_keeper_toml_or_keeper_instructions'),
})

const GateKeeperIssueBaseWireSchema = Schema.Struct({
  status: Schema.Literal('error'),
  runtime_class: Schema.Literal('keeper'),
  name: Schema.NonEmptyString,
  keepalive_running: Schema.Boolean,
  effective_meta_error: GateKeeperDirectoryIssueWireSchema,
})

const GateKeeperIssueWithMetaWireSchema = Schema.extend(
  GateKeeperIssueBaseWireSchema,
  Schema.Struct({
    meta: KeeperMetaWireSchema,
    agent_name: Schema.NonEmptyString,
    created_at: Schema.NonEmptyString,
    updated_at: Schema.NonEmptyString,
    autoboot_enabled: Schema.Boolean,
    proactive_enabled: Schema.Boolean,
  }),
)

const GateKeeperIssueWithoutMetaWireSchema = Schema.extend(
  GateKeeperIssueBaseWireSchema,
  Schema.Struct({
    meta: Schema.Null,
    agent_name: Schema.Null,
    created_at: Schema.Null,
    updated_at: Schema.Null,
  }),
)

const GateKeeperEntryWireSchema = Schema.Union(
  GateKeeperWireSchema,
  GateKeeperIssueWithMetaWireSchema,
  GateKeeperIssueWithoutMetaWireSchema,
)

const GateKeepersWireSchema = Schema.Struct({
  count: Schema.NonNegativeInt,
  keepers: Schema.Array(GateKeeperEntryWireSchema),
})

type GateKeeperEntryWire = Schema.Schema.Type<
  typeof GateKeeperEntryWireSchema
>
type GateKeepersWire = Schema.Schema.Type<typeof GateKeepersWireSchema>

function gateKeepersInvariantIssues(data: GateKeepersWire) {
  const issues: Array<{
    readonly path: ReadonlyArray<PropertyKey>
    readonly message: string
  }> = []

  if (data.count !== data.keepers.length) {
    issues.push({
      path: ['count'],
      message: 'must equal keepers.length',
    })
  }

  const seenNames = new Set<string>()
  for (const [index, keeper] of data.keepers.entries()) {
    if (seenNames.has(keeper.name)) {
      issues.push({
        path: ['keepers', index, 'name'],
        message: 'must be unique',
      })
    }
    seenNames.add(keeper.name)

    if ('effective_meta_error' in keeper) {
      if (keeper.effective_meta_error.keeper !== keeper.name) {
        issues.push({
          path: ['keepers', index, 'effective_meta_error', 'keeper'],
          message: 'must match the row name',
        })
      }
      if (keeper.meta !== null && keeper.meta.name !== keeper.name) {
        issues.push({
          path: ['keepers', index, 'meta', 'name'],
          message: 'must match the row name',
        })
      }
    } else if (keeper.meta.name !== keeper.name) {
      issues.push({
        path: ['keepers', index, 'meta', 'name'],
        message: 'must match the row name',
      })
    }
  }

  return issues
}

const GateKeepersValidatedWireSchema = GateKeepersWireSchema.pipe(
  Schema.filter(gateKeepersInvariantIssues),
)

export interface GateKeeper {
  readonly name: string
  readonly runtimeLabel: string
  readonly status: string
}

export interface GateKeeperDirectoryIssue {
  readonly keeperName: string
  readonly message: string
}

export interface GateKeepersData {
  readonly keepers: readonly GateKeeper[]
  readonly directoryIssues: readonly GateKeeperDirectoryIssue[]
}

export class GateKeepersSchemaDriftError extends Data.TaggedError(
  'GateKeepersSchemaDriftError',
)<{
  readonly domain: 'gate-keepers'
  readonly issues: ReadonlyArray<ParseResult.ArrayFormatterIssue>
  readonly message: string
}> {}

function schemaDriftError(
  error: ParseResult.ParseError,
): GateKeepersSchemaDriftError {
  const issues = ParseResult.ArrayFormatter.formatErrorSync(error)
  const details = issues
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return new GateKeepersSchemaDriftError({
    domain: 'gate-keepers',
    issues,
    message: `gate-keepers schema drift: ${details}`,
  })
}

function isDirectoryIssue(
  entry: GateKeeperEntryWire,
): entry is Extract<GateKeeperEntryWire, { readonly status: 'error' }> {
  return 'effective_meta_error' in entry
}

function toGateKeepersData(wire: GateKeepersWire): GateKeepersData {
  const keepers: GateKeeper[] = []
  const directoryIssues: GateKeeperDirectoryIssue[] = []

  for (const entry of wire.keepers) {
    if (isDirectoryIssue(entry)) {
      directoryIssues.push({
        keeperName: entry.name,
        message: entry.effective_meta_error.message,
      })
    } else {
      keepers.push({
        name: entry.name,
        runtimeLabel: entry.agent_name === entry.name ? '' : entry.agent_name,
        status: entry.status,
      })
    }
  }

  return {
    keepers,
    directoryIssues,
  }
}

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function decodeGateKeepers(
  data: unknown,
): Effect.Effect<GateKeepersData, GateKeepersSchemaDriftError> {
  return Schema.decodeUnknown(
    GateKeepersValidatedWireSchema,
    STRICT_PARSE_OPTIONS,
  )(data).pipe(
    Effect.map(toGateKeepersData),
    Effect.mapError(schemaDriftError),
  )
}

import { Data, Effect, Option, ParseResult, Schema } from 'effect'

const ConfigEntrySourceSchema = Schema.Literal(
  'env',
  'default',
  'derived',
  'runtime',
)

const ConfigEntryProvenanceWireSchema = Schema.Struct({
  kind: ConfigEntrySourceSchema,
  detail: Schema.NonEmptyString,
  derived_from: Schema.optional(Schema.Array(Schema.NonEmptyString)),
  env: Schema.NonEmptyString,
  raw_source: Schema.NonEmptyString,
  raw_env_present: Schema.Boolean,
  raw_env_blank: Schema.Boolean,
  default: Schema.String,
  sensitive: Schema.Boolean,
  value_redacted: Schema.Boolean,
})

const ConfigEntryWireSchema = Schema.Struct({
  env: Schema.NonEmptyString,
  description: Schema.NonEmptyString,
  value: Schema.OptionFromNullOr(Schema.String),
  default: Schema.String,
  source: ConfigEntrySourceSchema,
  source_detail: Schema.NonEmptyString,
  provenance: ConfigEntryProvenanceWireSchema,
  sensitive: Schema.Boolean,
})

const DashboardConfigServerWireSchema = Schema.Struct({
  version: Schema.NonEmptyString,
  git_commit: Schema.OptionFromNullOr(Schema.NonEmptyString),
  ocaml_version: Schema.NonEmptyString,
  uptime_seconds: Schema.JsonNumber.pipe(Schema.nonNegative()),
  pid: Schema.NonNegativeInt,
})

const DashboardConfigWireSchema = Schema.Struct({
  generated_at: Schema.NonEmptyString,
  server: DashboardConfigServerWireSchema,
  categories: Schema.Record({
    key: Schema.NonEmptyString,
    value: Schema.Array(ConfigEntryWireSchema),
  }),
})

type DashboardConfigWire = Schema.Schema.Type<
  typeof DashboardConfigWireSchema
>

function dashboardConfigInvariantIssues(data: DashboardConfigWire) {
  const issues: Array<{
    readonly path: ReadonlyArray<PropertyKey>
    readonly message: string
  }> = []

  for (const [category, entries] of Object.entries(data.categories)) {
    for (const [index, entry] of entries.entries()) {
      const path = ['categories', category, index] as const
      const provenance = entry.provenance
      if (entry.source !== provenance.kind) {
        issues.push({
          path: [...path, 'source'],
          message: 'must match provenance.kind',
        })
      }
      if (entry.source_detail !== provenance.detail) {
        issues.push({
          path: [...path, 'source_detail'],
          message: 'must match provenance.detail',
        })
      }
      if (entry.env !== provenance.env) {
        issues.push({
          path: [...path, 'env'],
          message: 'must match provenance.env',
        })
      }
      if (entry.default !== provenance.default) {
        issues.push({
          path: [...path, 'default'],
          message: 'must match provenance.default',
        })
      }
      if (entry.sensitive !== provenance.sensitive) {
        issues.push({
          path: [...path, 'sensitive'],
          message: 'must match provenance.sensitive',
        })
      }
      if (provenance.value_redacted && !entry.sensitive) {
        issues.push({
          path: [...path, 'provenance', 'value_redacted'],
          message: 'can only be true for sensitive entries',
        })
      }
    }
  }

  return issues
}

const DashboardConfigValidatedWireSchema = DashboardConfigWireSchema.pipe(
  Schema.filter(dashboardConfigInvariantIssues),
)

export type ConfigEntrySource = Schema.Schema.Type<
  typeof ConfigEntrySourceSchema
>

export interface ConfigEntry {
  readonly env: string
  readonly description: string
  readonly displayValue: string
  readonly defaultValue: string
  readonly source: ConfigEntrySource
  readonly sourceDetail: string
  readonly sensitive: boolean
}

export interface DashboardConfig {
  readonly server: {
    readonly version: string
    readonly ocamlVersion: string
    readonly uptimeSeconds: number
    readonly pid: number
  }
  readonly categories: Readonly<Record<string, readonly ConfigEntry[]>>
}

export class DashboardConfigSchemaDriftError extends Data.TaggedError(
  'DashboardConfigSchemaDriftError',
)<{
  readonly domain: 'dashboard-config'
  readonly issues: ReadonlyArray<ParseResult.ArrayFormatterIssue>
  readonly message: string
}> {}

function schemaDriftError(
  error: ParseResult.ParseError,
): DashboardConfigSchemaDriftError {
  const issues = ParseResult.ArrayFormatter.formatErrorSync(error)
  const details = issues
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return new DashboardConfigSchemaDriftError({
    domain: 'dashboard-config',
    issues,
    message: `dashboard-config schema drift: ${details}`,
  })
}

function toDashboardConfig(wire: DashboardConfigWire): DashboardConfig {
  const categories = Object.fromEntries(
    Object.entries(wire.categories).map(([category, entries]) => [
      category,
      entries.map(entry => ({
        env: entry.env,
        description: entry.description,
        displayValue: Option.getOrElse(entry.value, () => entry.default),
        defaultValue: entry.default,
        source: entry.source,
        sourceDetail: entry.source_detail,
        sensitive: entry.sensitive,
      })),
    ]),
  )

  return {
    server: {
      version: wire.server.version,
      ocamlVersion: wire.server.ocaml_version,
      uptimeSeconds: wire.server.uptime_seconds,
      pid: wire.server.pid,
    },
    categories,
  }
}

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function decodeDashboardConfig(
  data: unknown,
): Effect.Effect<DashboardConfig, DashboardConfigSchemaDriftError> {
  return Schema.decodeUnknown(
    DashboardConfigValidatedWireSchema,
    STRICT_PARSE_OPTIONS,
  )(data).pipe(
    Effect.map(toDashboardConfig),
    Effect.mapError(schemaDriftError),
  )
}

// Schema-at-boundary for GET /api/v1/dashboard/runtime-probe.
// The server projects runtime.toml provider metadata reachability only; it
// does not run inference or report model-load / KV-cache observations.

import { Data, Either, ParseResult, Schema } from 'effect'

const NonnegativeNumberSchema = Schema.JsonNumber.pipe(Schema.nonNegative())

const DashboardRuntimeProviderProbeStatusSchema = Schema.Literal(
  'reachable',
  'auth_failed',
  'endpoint_not_found',
  'server_error',
  'http_error',
  'skipped_cli',
  'invalid_execution_transport',
  'invalid_endpoint',
  'missing_auth',
  'network_error',
)

const DashboardRuntimeProbeStatusSchema = Schema.Literal(
  'reachable',
  'no_http_runtimes',
  'degraded',
  'unreachable',
  'warming_up',
)

const DashboardRuntimeProbeRefreshStateSchema = Schema.Literal(
  'fresh',
  'recent',
  'served_stale',
  'warming_up',
)

const DashboardRuntimeProviderProbeSchema = Schema.Struct({
  runtime_id: Schema.String,
  provider_id: Schema.String,
  provider_display_name: Schema.String,
  model_id: Schema.String,
  model_api_name: Schema.String,
  protocol: Schema.String,
  runtime_kind: Schema.Literal('cli', 'local', 'http'),
  transport: Schema.Literal('cli', 'http'),
  auth_kind: Schema.String,
  credential_required: Schema.Boolean,
  auth_present: Schema.Boolean,
  status: DashboardRuntimeProviderProbeStatusSchema,
  reachable: Schema.NullOr(Schema.Boolean),
  http_status: Schema.NullOr(Schema.NonNegativeInt),
  latency_ms: Schema.NullOr(NonnegativeNumberSchema),
  model_count: Schema.NullOr(Schema.NonNegativeInt),
  content_type: Schema.NullOr(Schema.String),
  downloaded_bytes: Schema.NullOr(Schema.NonNegativeInt),
  endpoint_url: Schema.NullOr(Schema.String),
  probe_url: Schema.NullOr(Schema.String),
  error: Schema.NullOr(Schema.String),
  checked_at: Schema.String,
})

const DashboardRuntimeProviderProbeSummarySchema = Schema.Struct({
  runtimes: Schema.NonNegativeInt,
  probed: Schema.NonNegativeInt,
  reachable: Schema.NonNegativeInt,
  failed: Schema.NonNegativeInt,
  skipped: Schema.NonNegativeInt,
  default_runtime_id: Schema.NullOr(Schema.String),
})

const DashboardRuntimeProbePayloadSchema = Schema.Struct({
  source: Schema.Literal('runtime.toml'),
  status: DashboardRuntimeProbeStatusSchema,
  probe_ok: Schema.Boolean,
  checked_at: Schema.String,
  summary: DashboardRuntimeProviderProbeSummarySchema,
  providers: Schema.Array(DashboardRuntimeProviderProbeSchema),
  errors: Schema.Array(Schema.String),
  observations: Schema.Array(Schema.String),
  limitations: Schema.Array(Schema.String),
})

type DashboardRuntimeProbePayloadWire = Schema.Schema.Type<
  typeof DashboardRuntimeProbePayloadSchema
>

function runtimeProbeInvariantIssues(data: DashboardRuntimeProbePayloadWire) {
  const issues: Array<{
    readonly path: ReadonlyArray<PropertyKey>
    readonly message: string
  }> = []
  const summary = data.summary
  if (summary.runtimes !== data.providers.length) {
    issues.push({ path: ['summary', 'runtimes'], message: 'must equal providers.length' })
  }
  if (summary.probed + summary.skipped !== summary.runtimes) {
    issues.push({ path: ['summary', 'probed'], message: 'probed + skipped must equal runtimes' })
  }
  if (summary.reachable + summary.failed !== summary.probed) {
    issues.push({ path: ['summary', 'reachable'], message: 'reachable + failed must equal probed' })
  }
  const countFailureEnvelope = summary.failed === 0
    && (data.status === 'warming_up' || data.status === 'unreachable')
  if (data.probe_ok !== (summary.failed === 0)
    && !(data.probe_ok === false && countFailureEnvelope)) {
    issues.push({ path: ['probe_ok'], message: 'must match failed count or a zero-count failure envelope' })
  }
  return issues
}

const DashboardRuntimeProbeValidatedPayloadSchema = DashboardRuntimeProbePayloadSchema.pipe(
  Schema.filter(runtimeProbeInvariantIssues),
)

const DashboardRuntimeProbeResponseSchema = Schema.Struct({
  generated_at: Schema.String,
  refreshed_at_unix: Schema.NullOr(NonnegativeNumberSchema),
  cache_ttl_sec: NonnegativeNumberSchema,
  cache_age_sec: Schema.NullOr(NonnegativeNumberSchema),
  cache_hit: Schema.Boolean,
  refresh_state: DashboardRuntimeProbeRefreshStateSchema,
  probe: DashboardRuntimeProbeValidatedPayloadSchema,
})

export type DashboardRuntimeProviderProbeStatus = Schema.Schema.Type<
  typeof DashboardRuntimeProviderProbeStatusSchema
>
export type DashboardRuntimeProbeStatus = Schema.Schema.Type<
  typeof DashboardRuntimeProbeStatusSchema
>
export type DashboardRuntimeProbeRefreshState = Schema.Schema.Type<
  typeof DashboardRuntimeProbeRefreshStateSchema
>
export type DashboardRuntimeProviderProbe = Schema.Schema.Type<
  typeof DashboardRuntimeProviderProbeSchema
>
export type DashboardRuntimeProviderProbeSummary = Schema.Schema.Type<
  typeof DashboardRuntimeProviderProbeSummarySchema
>
export type DashboardRuntimeProbePayload = Schema.Schema.Type<
  typeof DashboardRuntimeProbeValidatedPayloadSchema
>
export type DashboardRuntimeProbeResponse = Schema.Schema.Type<
  typeof DashboardRuntimeProbeResponseSchema
>

export class RuntimeProbeSchemaDriftError extends Data.TaggedError(
  'RuntimeProbeSchemaDriftError',
)<{
  readonly domain: 'runtime_probe'
  readonly issues: ReadonlyArray<ParseResult.ArrayFormatterIssue>
  readonly message: string
}> {}

function schemaDriftError(error: ParseResult.ParseError): RuntimeProbeSchemaDriftError {
  const issues = ParseResult.ArrayFormatter.formatErrorSync(error)
  const details = issues
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return new RuntimeProbeSchemaDriftError({
    domain: 'runtime_probe',
    issues,
    message: `runtime_probe schema drift: ${details}`,
  })
}

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function parseDashboardRuntimeProbeResponse(data: unknown): DashboardRuntimeProbeResponse {
  const parsed = Schema.decodeUnknownEither(
    DashboardRuntimeProbeResponseSchema,
    STRICT_PARSE_OPTIONS,
  )(data)
  if (Either.isLeft(parsed)) throw schemaDriftError(parsed.left)
  return parsed.right
}

// MASC Dashboard — Skills catalog REST client.
//
// Reads /api/v1/skills: the published workspace skill snapshot
// (masc.skill-snapshot/v1, lib/skill_snapshot) plus the optional exact
// parser-derived surface of each effective Skill.

import { Either, ParseResult, Schema } from 'effect'
import { validate as isUuid, version as uuidVersion } from 'uuid'
import { ApiRequestError, get, post, postControlPlane, type GetOptions } from './core'

export interface SkillIdentity {
  source_id: string
  package_id: string
  name: string
}

export interface SkillSnapshotEntry {
  identity: SkillIdentity
  content_revision: string
  description: string
  conformance: string
  diagnostics?: readonly string[]
  body_bytes: number
}

export type SkillSnapshotConfig =
  | {
      kind: 'configured'
      revision: string
      resource_read_max_bytes: number | null
    }
  | { kind: 'rejected'; source_revision: string; diagnostics: readonly string[] }
  | { kind: 'unreadable' }

export interface SkillSnapshot {
  snapshot_revision: string
  catalog_revision: string
  config: SkillSnapshotConfig
  sources: readonly unknown[]
  skills: readonly SkillSnapshotEntry[]
  effective_skills: readonly SkillIdentity[]
  shadows: readonly unknown[]
  rejections: readonly unknown[]
}

export interface SkillReference {
  identity: SkillIdentity
  content_revision: string
}

export interface SkillUsage {
  keeper: string
  invocations: number
  deliveries: number
  actions: number
  last_used_at: string
}

export interface SkillFlowDependency {
  node_id: string
  kind: 'data' | 'order' | 'data_and_order'
}

export interface SkillFlowNode {
  id: string
  tool_name: string
  dependencies: readonly SkillFlowDependency[]
  batch_index: number
  batch_size: number
  execution_mode: string
  statically_read_only: boolean | null
}

export interface SkillFlowBatch {
  index: number
  execution_mode: string
  node_ids: readonly string[]
}

export interface SkillFlow {
  nodes: readonly SkillFlowNode[]
  batches: readonly SkillFlowBatch[]
}

export interface SkillProfile {
  reference: SkillReference
  kind: string
  activation_tool: string
  execution: string
  capabilities: {
    as_skill: boolean
    as_tool: boolean
    batch: boolean
    parallel: boolean
    async: boolean
    tool_scope: string
  }
  context: {
    body_bytes: number
    eager_body_bytes: number
    discovery_bytes: number
    tool_schema_bytes: number | null
  }
  plan: {
    node_count: number
    batch_count: number
    parallel_batch_count: number
    max_parallelism: number
    statically_read_only: boolean | null
  }
  declaration: { start_line: number; end_line: number } | null
  flow: SkillFlow | null
}

export type SkillSurfaceProfile = Omit<SkillProfile, 'reference' | 'kind'>

export interface SkillEvidenceCoverage {
  composition_scope: 'exact_reference_latest_completed' | 'unavailable'
  composition_records_read: number
  composition_unavailable: readonly string[]
  coverage_complete: false
  activation_scope:
    | 'complete_retained_trace_snapshot'
    | 'incomplete_retained_trace_snapshot'
    | 'trace_store_unavailable'
  activation_sessions_inspected: number
  activation_ledgers_loaded: number
  activation_gaps: readonly Record<string, unknown>[]
  activation_owner_gap_count: number
}

export interface SkillActivationOwnerClaim {
  keeper: string
  source: 'current_meta' | 'trace_history' | 'runtime_manifest'
}

export interface SkillActivationOwner {
  status:
    | 'known'
    | 'not_claimed_in_retained_catalog'
    | 'conflicting'
    | 'incomplete'
    | 'catalog_unavailable'
  claims: readonly SkillActivationOwnerClaim[]
  gaps: readonly Record<string, unknown>[]
}

export interface SkillActivationEvidence {
  trace_id: string
  owner: SkillActivationOwner
  activation: Record<string, unknown>
}

export type SkillActivationSelection =
  | { selection: 'most_recent_observed'; evidence: SkillActivationEvidence }
  | {
      selection: 'most_recent_observed_timestamp_tie'
      evidence: readonly SkillActivationEvidence[]
    }

export interface SkillCompositionEvidence {
  schema: 'masc.skill-composition-evidence/v1'
  reference: SkillReference
  composition_run_id: string
  parent_tool_use_id: string
  parent_turn: number
  parent_planned_index: number
  request_id: string | null
  keeper: string
  composition_tool: string
  composition_execution: 'inline' | 'async'
  result: Record<string, unknown>
  executor_settlements: readonly Record<string, unknown>[]
  recorded_at: number
}

export interface SkillEvidenceResponse {
  schema: 'masc.skill-evidence/v5'
  status: 'observed' | 'not_observed_in_retained_coverage'
  reference: SkillReference
  activation: SkillActivationSelection | null
  composition: SkillCompositionEvidence | null
  coverage: SkillEvidenceCoverage
}

export interface WritableSkillSource { source_id: string }

export interface SkillEditorLoaded {
  status: 'ready'
  reference: SkillReference
  snapshot_revision: string
  source_text: string
  access: 'read_only' | 'read_write'
}

export interface SkillEditorPreview {
  profile: SkillProfile
  diagnostics: readonly string[]
}

export type SkillEditorSaveReceipt =
  | {
      status: 'unchanged' | 'saved_and_published'
      preview: SkillEditorPreview
      snapshot_revision: string
    }
  | {
      status: 'saved_but_unpublished'
      preview: SkillEditorPreview
      reason: string
    }

export type SkillEditorErrorKind = 'revision_conflict' | 'other'

export interface AsyncRequestRow {
  request_id: string
  keeper_name: string
  submitted_by: string
  status: string
  submitted_at: number
  elapsed_sec?: number
  completed_at?: number
  ok?: boolean
  result?: unknown
  worker_ownership: 'runtime_owned' | 'disk_only_ownership_unknown'
}

export interface AsyncStartupRecovery {
  lost: number
  finalized: number
  cleaned: number
  staging_files_inspected: number
  staging_files_deleted: number
  staging_files_preserved: number
  unreadable: number
  failed: number
  store_errors: readonly Record<string, unknown>[]
  record_errors: readonly Record<string, unknown>[]
}

export type AsyncRequestObservation =
  | {
      schema: 'masc.async-request-observation/v1'
      status: 'ready'
      summary: {
        active: number
        runtime_owned: number
        ownership_unknown: number
        record_errors: number
      }
      requests: readonly AsyncRequestRow[]
      record_errors: readonly Record<string, unknown>[]
      startup_recovery: AsyncStartupRecovery | null
    }
  | {
      schema: 'masc.async-request-observation/v1'
      status: 'unavailable'
      error: Record<string, unknown>
      startup_recovery: AsyncStartupRecovery | null
    }

interface SkillSurfaceBase {
  reference: SkillReference
  diagnostics?: readonly string[]
  usage?: readonly SkillUsage[]
}

export type SkillSurface =
  | (SkillSurfaceBase & {
      kind: 'instruction'
      profile: SkillSurfaceProfile
    })
  | (SkillSurfaceBase & {
      kind: 'composition'
      profile: SkillSurfaceProfile
    })
  | (SkillSurfaceBase & {
      kind: 'unavailable'
      error: string
    })

export type SkillsResponse =
  | {
      schema: string
      state: 'ready'
      snapshot: SkillSnapshot
      surfaces: readonly SkillSurface[]
      usage_coverage?: {
        ledgers_loaded: number
        unavailable: readonly string[]
      }
    }
  | { schema: string; state: 'not_registered' | 'uninitialized' }
  | {
      schema: string
      state: 'invalid_workspace'
      reason: { code: 'invalid_workspace' }
    }

export type SkillsContractErrorCode =
  | 'invalid_response'
  | 'ready_surfaces_missing'
  | 'ready_surfaces_empty'
  | 'ready_surfaces_invalid'
  | 'ready_surfaces_duplicate_reference'
  | 'ready_surface_missing_reference'
  | 'ready_surface_unexpected_reference'

export class SkillsContractError extends Error {
  readonly code: SkillsContractErrorCode

  constructor(code: SkillsContractErrorCode, detail: string) {
    super(`invalid skills response: ${detail}`)
    this.name = 'SkillsContractError'
    this.code = code
  }
}

function contractError(code: SkillsContractErrorCode, detail: string): never {
  throw new SkillsContractError(code, detail)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

const PositiveSafeIntegerSchema = Schema.Int.pipe(
  Schema.between(1, Number.MAX_SAFE_INTEGER),
)
const NonNegativeSafeIntegerSchema = Schema.Int.pipe(
  Schema.between(0, Number.MAX_SAFE_INTEGER),
)
const OptionalDiagnosticsSchema = Schema.optional(Schema.Array(Schema.String))

const SkillIdentitySchema = Schema.Struct({
  source_id: Schema.NonEmptyString,
  package_id: Schema.NonEmptyString,
  name: Schema.NonEmptyString,
})

const SkillReferenceSchema = Schema.Struct({
  identity: SkillIdentitySchema,
  content_revision: Schema.NonEmptyString,
})

const SkillUsageSchema = Schema.Struct({
  keeper: Schema.NonEmptyString,
  invocations: NonNegativeSafeIntegerSchema,
  deliveries: NonNegativeSafeIntegerSchema,
  actions: NonNegativeSafeIntegerSchema,
  last_used_at: Schema.String,
})

const SkillFlowSchema = Schema.Struct({
  nodes: Schema.Array(Schema.Struct({
    id: Schema.NonEmptyString,
    tool_name: Schema.NonEmptyString,
    dependencies: Schema.Array(Schema.Struct({
      node_id: Schema.NonEmptyString,
      kind: Schema.Literal('data', 'order', 'data_and_order'),
    })),
    batch_index: NonNegativeSafeIntegerSchema,
    batch_size: PositiveSafeIntegerSchema,
    execution_mode: Schema.NonEmptyString,
    statically_read_only: Schema.NullOr(Schema.Boolean),
  })),
  batches: Schema.Array(Schema.Struct({
    index: NonNegativeSafeIntegerSchema,
    execution_mode: Schema.NonEmptyString,
    node_ids: Schema.Array(Schema.NonEmptyString),
  })),
})

const UnknownRecordSchema = Schema.Record({
  key: Schema.String,
  value: Schema.Unknown,
})

const ToolOutputResultSchema = Schema.Struct({
  disposition: Schema.Literal('completed', 'deferred'),
  data: Schema.Unknown,
  tool_name: Schema.NonEmptyString,
  duration_ms: Schema.Number,
  metadata: Schema.optional(Schema.Unknown),
})

const ToolFailedResultSchema = Schema.Struct({
  disposition: Schema.Literal('failed'),
  data: Schema.Unknown,
  tool_name: Schema.NonEmptyString,
  duration_ms: Schema.Number,
  failure_class: Schema.Literal(
    'dependency_unavailable',
    'policy_rejection',
    'runtime_failure',
    'workflow_rejection',
    'operator_cancelled',
  ),
  message: Schema.String,
  metadata: Schema.optional(Schema.Unknown),
})

const ToolResultSchema = Schema.Union(ToolOutputResultSchema, ToolFailedResultSchema)

const CompositionNodeSchema = Schema.Struct({
  node_id: Schema.NonEmptyString,
  execution_id: Schema.NonEmptyString,
  tool_name: Schema.NonEmptyString,
  input: Schema.Unknown,
  schedule: Schema.Struct({
    planned_index: NonNegativeSafeIntegerSchema,
    batch_index: NonNegativeSafeIntegerSchema,
    batch_size: PositiveSafeIntegerSchema,
    execution_mode: Schema.Literal('serial', 'concurrent'),
  }),
  result: ToolResultSchema,
  tool_use_id: Schema.String,
  failure_effect_disposition: Schema.NullOr(Schema.Literal(
    'proven_pre_effect',
    'proven_post_effect',
    'effect_outcome_unknown',
  )),
  deferred_kind: Schema.NullOr(Schema.Literal(
    'generic_deferred',
    'external_effect_deferred',
  )),
  result_bytes: NonNegativeSafeIntegerSchema,
  truncated_to: Schema.NullOr(NonNegativeSafeIntegerSchema),
})

const SkillEvidenceResponseSchema = Schema.Struct({
  schema: Schema.Literal('masc.skill-evidence/v5'),
  status: Schema.Literal('observed', 'not_observed_in_retained_coverage'),
  reference: SkillReferenceSchema,
  activation: Schema.NullOr(Schema.Union(
    Schema.Struct({
      selection: Schema.Literal('most_recent_observed'),
      evidence: Schema.Struct({
        trace_id: Schema.NonEmptyString,
        owner: Schema.Struct({
          status: Schema.Literal(
            'known',
            'not_claimed_in_retained_catalog',
            'conflicting',
            'incomplete',
            'catalog_unavailable',
          ),
          claims: Schema.Array(Schema.Struct({
            keeper: Schema.NonEmptyString,
            source: Schema.Literal('current_meta', 'trace_history', 'runtime_manifest'),
          })),
          gaps: Schema.Array(UnknownRecordSchema),
        }),
        activation: UnknownRecordSchema,
      }),
    }),
    Schema.Struct({
      selection: Schema.Literal('most_recent_observed_timestamp_tie'),
      evidence: Schema.Array(Schema.Struct({
        trace_id: Schema.NonEmptyString,
        owner: Schema.Struct({
          status: Schema.Literal(
            'known',
            'not_claimed_in_retained_catalog',
            'conflicting',
            'incomplete',
            'catalog_unavailable',
          ),
          claims: Schema.Array(Schema.Struct({
            keeper: Schema.NonEmptyString,
            source: Schema.Literal('current_meta', 'trace_history', 'runtime_manifest'),
          })),
          gaps: Schema.Array(UnknownRecordSchema),
        }),
        activation: UnknownRecordSchema,
      })),
    }),
  )),
  composition: Schema.NullOr(Schema.Struct({
    schema: Schema.Literal('masc.skill-composition-evidence/v1'),
    reference: SkillReferenceSchema,
    composition_run_id: Schema.NonEmptyString,
    parent_tool_use_id: Schema.String,
    parent_turn: NonNegativeSafeIntegerSchema,
    parent_planned_index: NonNegativeSafeIntegerSchema,
    request_id: Schema.NullOr(Schema.NonEmptyString),
    keeper: Schema.NonEmptyString,
    composition_tool: Schema.NonEmptyString,
    composition_execution: Schema.Literal('inline', 'async'),
    result: ToolResultSchema,
    executor_settlements: Schema.Array(CompositionNodeSchema),
    recorded_at: Schema.Number,
  })),
  coverage: Schema.Struct({
    composition_scope: Schema.Literal(
      'exact_reference_latest_completed',
      'unavailable',
    ),
    composition_records_read: NonNegativeSafeIntegerSchema,
    composition_unavailable: Schema.Array(Schema.String),
    coverage_complete: Schema.Literal(false),
    activation_scope: Schema.Literal(
      'complete_retained_trace_snapshot',
      'incomplete_retained_trace_snapshot',
      'trace_store_unavailable',
    ),
    activation_sessions_inspected: NonNegativeSafeIntegerSchema,
    activation_ledgers_loaded: NonNegativeSafeIntegerSchema,
    activation_gaps: Schema.Array(UnknownRecordSchema),
    activation_owner_gap_count: NonNegativeSafeIntegerSchema,
  }),
})

const AsyncStartupRecoverySchema = Schema.Struct({
  lost: NonNegativeSafeIntegerSchema,
  finalized: NonNegativeSafeIntegerSchema,
  cleaned: NonNegativeSafeIntegerSchema,
  staging_files_inspected: NonNegativeSafeIntegerSchema,
  staging_files_deleted: NonNegativeSafeIntegerSchema,
  staging_files_preserved: NonNegativeSafeIntegerSchema,
  unreadable: NonNegativeSafeIntegerSchema,
  failed: NonNegativeSafeIntegerSchema,
  store_errors: Schema.Array(UnknownRecordSchema),
  record_errors: Schema.Array(UnknownRecordSchema),
})

const AsyncRequestObservationSchema = Schema.Union(
  Schema.Struct({
    schema: Schema.Literal('masc.async-request-observation/v1'),
    status: Schema.Literal('ready'),
    summary: Schema.Struct({
      active: NonNegativeSafeIntegerSchema,
      runtime_owned: NonNegativeSafeIntegerSchema,
      ownership_unknown: NonNegativeSafeIntegerSchema,
      record_errors: NonNegativeSafeIntegerSchema,
    }),
    requests: Schema.Array(Schema.Struct({
      request_id: Schema.NonEmptyString,
      keeper_name: Schema.NonEmptyString,
      submitted_by: Schema.NonEmptyString,
      status: Schema.NonEmptyString,
      submitted_at: Schema.Number,
      elapsed_sec: Schema.optional(Schema.Number),
      completed_at: Schema.optional(Schema.Number),
      ok: Schema.optional(Schema.Boolean),
      result: Schema.optional(Schema.Unknown),
      worker_ownership: Schema.Literal(
        'runtime_owned',
        'disk_only_ownership_unknown',
      ),
    })),
    record_errors: Schema.Array(UnknownRecordSchema),
    startup_recovery: Schema.NullOr(AsyncStartupRecoverySchema),
  }),
  Schema.Struct({
    schema: Schema.Literal('masc.async-request-observation/v1'),
    status: Schema.Literal('unavailable'),
    error: UnknownRecordSchema,
    startup_recovery: Schema.NullOr(AsyncStartupRecoverySchema),
  }),
)

const SkillProfileDetailsFields = {
  activation_tool: Schema.NonEmptyString,
  execution: Schema.NonEmptyString,
  capabilities: Schema.Struct({
    as_skill: Schema.Boolean,
    as_tool: Schema.Boolean,
    batch: Schema.Boolean,
    parallel: Schema.Boolean,
    async: Schema.Boolean,
    tool_scope: Schema.NonEmptyString,
  }),
  context: Schema.Struct({
    body_bytes: NonNegativeSafeIntegerSchema,
    eager_body_bytes: NonNegativeSafeIntegerSchema,
    discovery_bytes: NonNegativeSafeIntegerSchema,
    tool_schema_bytes: Schema.NullOr(NonNegativeSafeIntegerSchema),
  }),
  plan: Schema.Struct({
    node_count: NonNegativeSafeIntegerSchema,
    batch_count: NonNegativeSafeIntegerSchema,
    parallel_batch_count: NonNegativeSafeIntegerSchema,
    max_parallelism: NonNegativeSafeIntegerSchema,
    statically_read_only: Schema.NullOr(Schema.Boolean),
  }),
  declaration: Schema.NullOr(Schema.Struct({
    start_line: PositiveSafeIntegerSchema,
    end_line: PositiveSafeIntegerSchema,
  })),
  flow: Schema.NullOr(SkillFlowSchema),
} as const

const SkillProfileSchema = Schema.Struct({
  reference: SkillReferenceSchema,
  kind: Schema.NonEmptyString,
  ...SkillProfileDetailsFields,
})

const SkillSurfaceProfileSchema = Schema.Struct(SkillProfileDetailsFields)

const SkillEditorPreviewSchema = Schema.Struct({
  profile: SkillProfileSchema,
  diagnostics: Schema.Array(Schema.String),
})

const SkillEditorLoadedSchema = Schema.Struct({
  status: Schema.Literal('ready'),
  reference: SkillReferenceSchema,
  snapshot_revision: Schema.NonEmptyString,
  source_text: Schema.String,
  access: Schema.Literal('read_only', 'read_write'),
})

const SkillEditorPreviewResponseSchema = Schema.Struct({
  ok: Schema.Literal(true),
  status: Schema.Literal('valid'),
  preview: SkillEditorPreviewSchema,
})

const SkillEditorSaveReceiptSchema = Schema.Union(
  Schema.Struct({
    status: Schema.Literal('unchanged', 'saved_and_published'),
    preview: SkillEditorPreviewSchema,
    snapshot_revision: Schema.NonEmptyString,
  }),
  Schema.Struct({
    status: Schema.Literal('saved_but_unpublished'),
    preview: SkillEditorPreviewSchema,
    reason: Schema.NonEmptyString,
  }),
)

const OptionalUsageSchema = Schema.optional(Schema.Array(SkillUsageSchema))

const SkillSurfaceSchema = Schema.Union(
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('instruction'),
    diagnostics: OptionalDiagnosticsSchema,
    profile: SkillSurfaceProfileSchema,
    usage: OptionalUsageSchema,
  }),
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('composition'),
    diagnostics: OptionalDiagnosticsSchema,
    profile: SkillSurfaceProfileSchema,
    usage: OptionalUsageSchema,
  }),
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('unavailable'),
    error: Schema.NonEmptyString,
    diagnostics: OptionalDiagnosticsSchema,
    usage: OptionalUsageSchema,
  }),
)

const SkillSnapshotConfigSchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('configured'),
    revision: Schema.NonEmptyString,
    resource_read_max_bytes: Schema.NullOr(PositiveSafeIntegerSchema),
  }),
  Schema.Struct({
    kind: Schema.Literal('rejected'),
    source_revision: Schema.NonEmptyString,
    diagnostics: Schema.Array(Schema.String),
  }),
  Schema.Struct({ kind: Schema.Literal('unreadable') }),
)

const SkillSnapshotEntrySchema = Schema.Struct({
  identity: SkillIdentitySchema,
  content_revision: Schema.NonEmptyString,
  description: Schema.NonEmptyString,
  conformance: Schema.NonEmptyString,
  diagnostics: Schema.Array(Schema.String),
  body_bytes: Schema.NonNegativeInt,
})

const SkillSnapshotSchema = Schema.Struct({
  snapshot_revision: Schema.NonEmptyString,
  catalog_revision: Schema.NonEmptyString,
  config: SkillSnapshotConfigSchema,
  sources: Schema.Array(Schema.Unknown),
  skills: Schema.Array(SkillSnapshotEntrySchema),
  effective_skills: Schema.Array(SkillIdentitySchema),
  shadows: Schema.Array(Schema.Unknown),
  rejections: Schema.Array(Schema.Unknown),
})

const ReadySkillsResponseSchema = Schema.Struct({
  schema: Schema.Literal('masc.skill-snapshot/v1'),
  state: Schema.Literal('ready'),
  snapshot: SkillSnapshotSchema,
  surfaces: Schema.Array(SkillSurfaceSchema),
  usage_coverage: Schema.optional(Schema.Struct({
    ledgers_loaded: NonNegativeSafeIntegerSchema,
    unavailable: Schema.Array(Schema.String),
  })),
})

const UnreadySkillsResponseSchema = Schema.Union(
  Schema.Struct({
    schema: Schema.Literal('masc.skill-snapshot/v1'),
    state: Schema.Literal('not_registered', 'uninitialized'),
  }),
  Schema.Struct({
    schema: Schema.Literal('masc.skill-snapshot/v1'),
    state: Schema.Literal('invalid_workspace'),
    reason: Schema.Struct({ code: Schema.Literal('invalid_workspace') }),
  }),
)

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

function decodeWithSchema<A, I>(
  schema: Schema.Schema<A, I>,
  raw: unknown,
  code: SkillsContractErrorCode,
): A {
  const result = Schema.decodeUnknownEither(schema, STRICT_PARSE_OPTIONS)(raw)
  if (Either.isRight(result)) return result.right
  const detail = ParseResult.ArrayFormatter.formatErrorSync(result.left)
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return contractError(code, detail)
}

function referenceKey(reference: SkillReference): string {
  const { identity } = reference
  return [
    identity.source_id,
    identity.package_id,
    identity.name,
    reference.content_revision,
  ].join('\u0000')
}

function validateSurfaceCoverage(
  snapshot: SkillSnapshot,
  surfaces: readonly SkillSurface[],
): void {
  if (snapshot.skills.length > 0 && surfaces.length === 0) {
    contractError(
      'ready_surfaces_empty',
      'root.surfaces must project every non-empty snapshot skill',
    )
  }
  const expected = new Set(
    snapshot.skills.map(entry => referenceKey({
      identity: entry.identity,
      content_revision: entry.content_revision,
    })),
  )
  const observed = new Set<string>()
  for (const surface of surfaces) {
    const key = referenceKey(surface.reference)
    if (observed.has(key)) {
      contractError(
        'ready_surfaces_duplicate_reference',
        'root.surfaces contains a duplicate exact reference',
      )
    }
    if (!expected.has(key)) {
      contractError(
        'ready_surface_unexpected_reference',
        'root.surfaces contains a reference absent from root.snapshot.skills',
      )
    }
    observed.add(key)
  }
  if (observed.size !== expected.size) {
    contractError(
      'ready_surface_missing_reference',
      'root.surfaces does not cover every exact snapshot reference',
    )
  }
}

export function decodeSkillsResponse(raw: unknown): SkillsResponse {
  if (!isRecord(raw)) contractError('invalid_response', 'root must be an object')
  if (raw.state !== 'ready') {
    return decodeWithSchema(UnreadySkillsResponseSchema, raw, 'invalid_response')
  }
  if (!Object.hasOwn(raw, 'surfaces')) {
    contractError('ready_surfaces_missing', 'root.surfaces is required for ready state')
  }
  if (!Array.isArray(raw.surfaces)) {
    contractError('ready_surfaces_invalid', 'root.surfaces must be an array')
  }
  const snapshotSkills = isRecord(raw.snapshot) ? raw.snapshot.skills : undefined
  if (Array.isArray(snapshotSkills) && snapshotSkills.length > 0 && raw.surfaces.length === 0) {
    contractError(
      'ready_surfaces_empty',
      'root.surfaces must project every non-empty snapshot skill',
    )
  }
  const decoded = decodeWithSchema(ReadySkillsResponseSchema, raw, 'ready_surfaces_invalid')
  validateSurfaceCoverage(decoded.snapshot, decoded.surfaces)
  return decoded
}

export async function fetchSkills(opts: GetOptions = {}): Promise<SkillsResponse> {
  const raw = await get<unknown>('/api/v1/skills', opts)
  return decodeSkillsResponse(raw)
}

export function decodeSkillEvidenceResponse(raw: unknown): SkillEvidenceResponse {
  const decoded = decodeWithSchema(SkillEvidenceResponseSchema, raw, 'invalid_response')
  const observed = decoded.activation !== null || decoded.composition !== null
  if ((decoded.status === 'observed') !== observed) {
    contractError('invalid_response', 'skill evidence status disagrees with its observations')
  }
  const activationEvidence = decoded.activation === null
    ? []
    : decoded.activation.selection === 'most_recent_observed'
      ? [decoded.activation.evidence]
      : decoded.activation.evidence
  if (decoded.activation?.selection === 'most_recent_observed_timestamp_tie'
    && activationEvidence.length < 2) {
    contractError('invalid_response', 'activation timestamp tie requires at least two traces')
  }
  let ownerGapCount = 0
  for (const evidence of activationEvidence) {
    const { status, claims, gaps } = evidence.owner
    const ownerAgrees = status === 'known'
      ? claims.length === 1 && gaps.length === 0
      : status === 'not_claimed_in_retained_catalog'
        ? claims.length === 0 && gaps.length === 0
        : status === 'conflicting'
          ? claims.length >= 2 && gaps.length === 0
          : status === 'incomplete'
            ? gaps.length > 0
            : claims.length === 0 && gaps.length > 0
    if (!ownerAgrees) {
      contractError('invalid_response', 'activation owner status disagrees with claims or gaps')
    }
    const identity = isRecord(evidence.activation.identity)
      ? evidence.activation.identity
      : null
    if (identity === null
      || identity.source_id !== decoded.reference.identity.source_id
      || identity.package_id !== decoded.reference.identity.package_id
      || identity.name !== decoded.reference.identity.name
      || evidence.activation.content_revision !== decoded.reference.content_revision) {
      contractError('invalid_response', 'activation reference disagrees with evidence envelope')
    }
    ownerGapCount += gaps.length
  }
  if (decoded.composition !== null) {
    if (referenceKey(decoded.composition.reference) !== referenceKey(decoded.reference)) {
      contractError('invalid_response', 'composition reference disagrees with evidence envelope')
    }
    if (!isUuid(decoded.composition.composition_run_id)
      || uuidVersion(decoded.composition.composition_run_id) !== 7) {
      contractError('invalid_response', 'composition_run_id must be UUIDv7')
    }
    const requestIdentityAgrees = decoded.composition.composition_execution === 'inline'
      ? decoded.composition.request_id === null
      : decoded.composition.request_id !== null && decoded.composition.request_id.trim() !== ''
    if (!requestIdentityAgrees) {
      contractError('invalid_response', 'composition execution disagrees with request_id')
    }
    const validResultDuration = Number.isFinite(decoded.composition.result.duration_ms)
      && decoded.composition.result.duration_ms >= 0
      && decoded.composition.result.tool_name === decoded.composition.composition_tool
      && Number.isFinite(decoded.composition.recorded_at)
    const validNodes = decoded.composition.executor_settlements.every(node =>
      Number.isFinite(node.result.duration_ms)
      && node.result.duration_ms >= 0
      && node.result.tool_name === node.tool_name
      && node.schedule.batch_index < node.schedule.batch_size
      && (node.truncated_to === null
        || (node.truncated_to >= 0 && node.truncated_to <= node.result_bytes)))
    if (!validResultDuration || !validNodes) {
      contractError('invalid_response', 'composition result violates typed numeric invariants')
    }
  }
  const { composition_scope: scope, composition_records_read: read } = decoded.coverage
  const coverageAgrees = scope === 'exact_reference_latest_completed'
    ? (decoded.composition === null ? read === 0 : read === 1)
    : decoded.composition === null
      && read === 0
      && decoded.coverage.composition_unavailable.length > 0
  if (!coverageAgrees) {
    contractError('invalid_response', 'composition coverage disagrees with its record')
  }
  const coverage = decoded.coverage
  const activationCoverageAgrees = coverage.activation_ledgers_loaded
      <= coverage.activation_sessions_inspected
    && coverage.activation_owner_gap_count === ownerGapCount
    && (coverage.activation_scope === 'complete_retained_trace_snapshot'
      ? coverage.activation_gaps.length === 0
      : coverage.activation_gaps.length > 0)
  if (!activationCoverageAgrees) {
    contractError('invalid_response', 'activation coverage disagrees with retained snapshot')
  }
  return decoded
}

export async function fetchSkillEvidence(reference: SkillReference): Promise<SkillEvidenceResponse> {
  const raw = await post<unknown>('/api/v1/skills/evidence', { reference })
  return decodeSkillEvidenceResponse(raw)
}

export function decodeAsyncRequestObservation(raw: unknown): AsyncRequestObservation {
  const decoded = decodeWithSchema(
    AsyncRequestObservationSchema,
    raw,
    'invalid_response',
  )
  if (decoded.status === 'ready') {
    const { active, runtime_owned: owned, ownership_unknown: unknown } = decoded.summary
    if (active !== decoded.requests.length || active !== owned + unknown) {
      contractError('invalid_response', 'async request summary disagrees with request rows')
    }
  }
  return decoded
}

export async function fetchAsyncRequestObservation(
  opts: GetOptions = {},
): Promise<AsyncRequestObservation> {
  const raw = await get<unknown>('/api/v1/async-requests', opts)
  return decodeAsyncRequestObservation(raw)
}

export async function fetchWritableSkillSources(): Promise<readonly WritableSkillSource[]> {
  const response = await get<{ status: string; sources: readonly WritableSkillSource[] }>(
    '/api/v1/skills/editor/sources',
  )
  return response.sources
}

function skillEditorBody(reference: SkillReference, sourceText?: string): Record<string, unknown> {
  return sourceText === undefined
    ? { reference }
    : { reference, source_text: sourceText }
}

export function decodeSkillEditorLoaded(raw: unknown): SkillEditorLoaded {
  return decodeWithSchema(SkillEditorLoadedSchema, raw, 'invalid_response')
}

export function decodeSkillEditorPreview(raw: unknown): SkillEditorPreview {
  return decodeWithSchema(
    SkillEditorPreviewResponseSchema,
    raw,
    'invalid_response',
  ).preview
}

export function decodeSkillEditorSaveReceipt(raw: unknown): SkillEditorSaveReceipt {
  return decodeWithSchema(SkillEditorSaveReceiptSchema, raw, 'invalid_response')
}

export function classifySkillEditorError(error: unknown): SkillEditorErrorKind {
  if (!(error instanceof ApiRequestError) || error.status !== 409) return 'other'
  const responseCode = isRecord(error.responseData) && typeof error.responseData.code === 'string'
    ? error.responseData.code
    : null
  return error.errorCode === 'revision_conflict' || responseCode === 'revision_conflict'
    ? 'revision_conflict'
    : 'other'
}

export async function readSkillSource(reference: SkillReference): Promise<SkillEditorLoaded> {
  return decodeSkillEditorLoaded(
    await post<unknown>('/api/v1/skills/editor/read', skillEditorBody(reference)),
  )
}

export async function previewSkillSource(
  reference: SkillReference,
  sourceText: string,
): Promise<SkillEditorPreview> {
  return decodeSkillEditorPreview(
    await post<unknown>(
      '/api/v1/skills/editor/preview',
      skillEditorBody(reference, sourceText),
    ),
  )
}

export async function saveSkillSource(
  reference: SkillReference,
  sourceText: string,
): Promise<SkillEditorSaveReceipt> {
  return decodeSkillEditorSaveReceipt(
    await postControlPlane<unknown>(
      '/api/v1/skills/editor/save',
      skillEditorBody(reference, sourceText),
    ),
  )
}

/** Mirror of Server_skill_editor.create_outcome_to_yojson: the server
 * answers exactly created_and_published or created_but_unpublished (with
 * the reason). Anything else is drift, not a state to invent a label for —
 * the old `?? 'created'` default reported a status the server never sends
 * and hid the not-published reason. */
export type SkillCreateReceipt =
  | { status: 'created_and_published' }
  | { status: 'created_but_unpublished'; reason: string }

export function decodeSkillCreateReceipt(raw: unknown): SkillCreateReceipt {
  if (typeof raw === 'object' && raw !== null) {
    const record = raw as Record<string, unknown>
    if (record.status === 'created_and_published') {
      return { status: 'created_and_published' }
    }
    if (record.status === 'created_but_unpublished' && typeof record.reason === 'string') {
      return { status: 'created_but_unpublished', reason: record.reason }
    }
  }
  const status = typeof raw === 'object' && raw !== null
    ? (raw as Record<string, unknown>).status ?? null
    : null
  throw new Error(
    `skill create receipt carried an unrecognized status: ${JSON.stringify(status)}`,
  )
}

export async function createSkill(input: {
  source_id: string
  package_id: string
  source_text: string
}): Promise<SkillCreateReceipt> {
  return decodeSkillCreateReceipt(
    await post<Record<string, unknown>>('/api/v1/skills/editor/create', input),
  )
}

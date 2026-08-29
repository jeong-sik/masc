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
  body_bytes: number
}

export type SkillDocumentField =
  | {
      kind: 'standard'
      name: 'name' | 'description' | 'license' | 'compatibility' | 'metadata' | 'allowed-tools'
    }
  | { kind: 'extension'; name: string }

export type SkillNameViolation =
  | { kind: 'empty_name' }
  | { kind: 'name_too_long'; length: number; maximum: number }
  | { kind: 'name_not_lowercase' }
  | { kind: 'name_starts_with_hyphen' }
  | { kind: 'name_ends_with_hyphen' }
  | { kind: 'name_has_consecutive_hyphens' }
  | { kind: 'name_has_invalid_character' }

type SkillDiagnostic<Code extends string> = { code: Code; message: string }

export type SkillDocumentDiagnostic =
  | SkillDiagnostic<'missing_frontmatter'>
  | SkillDiagnostic<'byte_order_mark'>
  | SkillDiagnostic<'unterminated_frontmatter'>
  | (SkillDiagnostic<'malformed_yaml'> & { detail: string })
  | SkillDiagnostic<'frontmatter_not_mapping'>
  | (SkillDiagnostic<'duplicate_field'> & { field: SkillDocumentField })
  | (SkillDiagnostic<'duplicate_metadata_key'> & { key: string })
  | (SkillDiagnostic<'unexpected_frontmatter_field'> & { field: string })
  | SkillDiagnostic<'missing_name'>
  | SkillDiagnostic<'missing_description'>
  | (SkillDiagnostic<'invalid_field_type'> & {
      field: SkillDocumentField
      expected: 'string' | 'string_mapping'
    })
  | (SkillDiagnostic<'invalid_name'> & {
      name: string
      violations: readonly SkillNameViolation[]
    })
  | (SkillDiagnostic<'name_mismatch'> & { declared: string; directory: string })
  | (SkillDiagnostic<'description_too_long'> & { length: number })
  | SkillDiagnostic<'compatibility_empty'>
  | (SkillDiagnostic<'compatibility_too_long'> & { length: number })
  | (SkillDiagnostic<'invalid_metadata_value'> & { key: string })

export type SkillSnapshotRejectionReason =
  | { kind: 'document_rejected'; diagnostics: readonly SkillDocumentDiagnostic[] }
  | { kind: 'document_unreadable' }
  | { kind: 'exact_identity_duplicate' }
  | { kind: 'invalid_package_id' }

export interface SkillSnapshotRejection {
  source_index: number
  source_id: string
  package_id: string | null
  content_revision: string | null
  reason: SkillSnapshotRejectionReason
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
  rejections: readonly SkillSnapshotRejection[]
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

const TaskInstructionOriginSchema = Schema.Struct({
  kind: Schema.Literal('task_instruction'),
  task_ids: Schema.NonEmptyArray(Schema.NonEmptyString),
})
const SessionInstructionOriginSchema = Schema.Struct({
  kind: Schema.Literal('session_instruction'),
})
const TaskCompositionOriginSchema = Schema.Struct({
  kind: Schema.Literal('task_composition'),
  task_ids: Schema.NonEmptyArray(Schema.NonEmptyString),
})
const SessionCompositionOriginSchema = Schema.Struct({
  kind: Schema.Literal('session_composition'),
})
const ServedContentSchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('skill_body'),
    bytes: NonNegativeSafeIntegerSchema,
    sha256: Schema.NonEmptyString,
  }),
  Schema.Struct({
    kind: Schema.Literal('skill_resource'),
    relative_path: Schema.NonEmptyString,
    bytes: NonNegativeSafeIntegerSchema,
    sha256: Schema.NonEmptyString,
  }),
)
const SkillInvocationSchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('instruction'),
    origin: Schema.Union(TaskInstructionOriginSchema, SessionInstructionOriginSchema),
    served_content: ServedContentSchema,
  }),
  Schema.Struct({
    kind: Schema.Literal('composition'),
    origin: Schema.Union(TaskCompositionOriginSchema, SessionCompositionOriginSchema),
    tool_name: Schema.NonEmptyString,
  }),
)
const ActionIdentitySchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('call_id'), call_id: Schema.NonEmptyString }),
  Schema.Struct({
    kind: Schema.Literal('provider_step'),
    conversation_id: Schema.NonEmptyString,
    step_index: NonNegativeSafeIntegerSchema,
  }),
)
const SkillActionSchema = Schema.Struct({
  identity: ActionIdentitySchema,
  tool_name: Schema.NonEmptyString,
  runtime_id: Schema.NonEmptyString,
  agent_core_turn: NonNegativeSafeIntegerSchema,
  observed_at: Schema.NonEmptyString,
})
const SkillDeliverySchema = Schema.Struct({
  boundary: Schema.Struct({
    kind: Schema.Literal('model_response', 'official_client_result_handoff'),
    agent_core_turn: NonNegativeSafeIntegerSchema,
  }),
  runtime_id: Schema.NonEmptyString,
  delivered_at: Schema.NonEmptyString,
  content_bytes: NonNegativeSafeIntegerSchema,
  content_sha256: Schema.NonEmptyString,
})
const SkillActivationPayloadSchema = Schema.Struct({
  identity: SkillIdentitySchema,
  content_revision: Schema.NonEmptyString,
  snapshot_revision: Schema.NonEmptyString,
  turn_ref: Schema.NonEmptyString,
  runtime_id: Schema.NonEmptyString,
  skill_tool_use_id: Schema.NonEmptyString,
  agent_core_turn: NonNegativeSafeIntegerSchema,
  invocation: SkillInvocationSchema,
  delivery: Schema.NullOr(SkillDeliverySchema),
  actions: Schema.Array(SkillActionSchema),
  activated_at: Schema.NonEmptyString,
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
        activation: SkillActivationPayloadSchema,
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
        activation: SkillActivationPayloadSchema,
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
  body_bytes: Schema.NonNegativeInt,
})

const SkillDocumentFieldSchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('standard'),
    name: Schema.Literal(
      'name',
      'description',
      'license',
      'compatibility',
      'metadata',
      'allowed-tools',
    ),
  }),
  Schema.Struct({ kind: Schema.Literal('extension'), name: Schema.NonEmptyString }),
)

const SkillNameViolationSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('empty_name') }),
  Schema.Struct({
    kind: Schema.Literal('name_too_long'),
    length: Schema.NonNegativeInt,
    maximum: Schema.Positive,
  }),
  Schema.Struct({ kind: Schema.Literal('name_not_lowercase') }),
  Schema.Struct({ kind: Schema.Literal('name_starts_with_hyphen') }),
  Schema.Struct({ kind: Schema.Literal('name_ends_with_hyphen') }),
  Schema.Struct({ kind: Schema.Literal('name_has_consecutive_hyphens') }),
  Schema.Struct({ kind: Schema.Literal('name_has_invalid_character') }),
)

const diagnosticBase = <Code extends string>(code: Code) => ({
  code: Schema.Literal(code),
  message: Schema.NonEmptyString,
})

const SkillDocumentDiagnosticSchema = Schema.Union(
  Schema.Struct(diagnosticBase('missing_frontmatter')),
  Schema.Struct(diagnosticBase('byte_order_mark')),
  Schema.Struct(diagnosticBase('unterminated_frontmatter')),
  Schema.Struct({ ...diagnosticBase('malformed_yaml'), detail: Schema.NonEmptyString }),
  Schema.Struct(diagnosticBase('frontmatter_not_mapping')),
  Schema.Struct({
    ...diagnosticBase('duplicate_field'),
    field: SkillDocumentFieldSchema,
  }),
  Schema.Struct({
    ...diagnosticBase('duplicate_metadata_key'),
    key: Schema.NonEmptyString,
  }),
  Schema.Struct({
    ...diagnosticBase('unexpected_frontmatter_field'),
    field: Schema.NonEmptyString,
  }),
  Schema.Struct(diagnosticBase('missing_name')),
  Schema.Struct(diagnosticBase('missing_description')),
  Schema.Struct({
    ...diagnosticBase('invalid_field_type'),
    field: SkillDocumentFieldSchema,
    expected: Schema.Literal('string', 'string_mapping'),
  }),
  Schema.Struct({
    ...diagnosticBase('invalid_name'),
    name: Schema.String,
    violations: Schema.Array(SkillNameViolationSchema),
  }),
  Schema.Struct({
    ...diagnosticBase('name_mismatch'),
    declared: Schema.String,
    directory: Schema.String,
  }),
  Schema.Struct({
    ...diagnosticBase('description_too_long'),
    length: Schema.NonNegativeInt,
  }),
  Schema.Struct(diagnosticBase('compatibility_empty')),
  Schema.Struct({
    ...diagnosticBase('compatibility_too_long'),
    length: Schema.NonNegativeInt,
  }),
  Schema.Struct({
    ...diagnosticBase('invalid_metadata_value'),
    key: Schema.NonEmptyString,
  }),
)

const SkillSnapshotRejectionReasonSchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('document_rejected'),
    diagnostics: Schema.Array(SkillDocumentDiagnosticSchema),
  }),
  Schema.Struct({ kind: Schema.Literal('document_unreadable') }),
  Schema.Struct({ kind: Schema.Literal('exact_identity_duplicate') }),
  Schema.Struct({ kind: Schema.Literal('invalid_package_id') }),
)

const SkillSnapshotRejectionSchema = Schema.Struct({
  source_index: Schema.NonNegativeInt,
  source_id: Schema.NonEmptyString,
  package_id: Schema.NullOr(Schema.NonEmptyString),
  content_revision: Schema.NullOr(Schema.NonEmptyString),
  reason: SkillSnapshotRejectionReasonSchema,
})

const SkillSnapshotSchema = Schema.Struct({
  snapshot_revision: Schema.NonEmptyString,
  catalog_revision: Schema.NonEmptyString,
  config: SkillSnapshotConfigSchema,
  sources: Schema.Array(Schema.Unknown),
  skills: Schema.Array(SkillSnapshotEntrySchema),
  effective_skills: Schema.Array(SkillIdentitySchema),
  shadows: Schema.Array(Schema.Unknown),
  rejections: Schema.Array(SkillSnapshotRejectionSchema),
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

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort()
  return actual.length === expected.length
    && [...expected].sort().every((field, index) => field === actual[index])
}

function isString(value: unknown): value is string {
  return typeof value === 'string'
}

function isPositiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && typeof value === 'number' && value > 0
}

const filesystemOperations = new Set([
  'open_directory',
  'read_directory',
  'close_directory',
  'stat_entry',
])
const fileKinds = new Set([
  'regular',
  'directory',
  'character_device',
  'block_device',
  'symbolic_link',
  'fifo',
  'socket',
])

function isFilesystemGap(gap: Record<string, unknown>, code: string): boolean {
  return hasExactKeys(gap, ['code', 'operation', 'path', 'detail'])
    && gap.code === code
    && isString(gap.operation)
    && filesystemOperations.has(gap.operation)
    && isString(gap.path)
    && isString(gap.detail)
}

function isManifestCause(value: unknown): boolean {
  if (!isRecord(value) || !isString(value.code)) return false
  switch (value.code) {
    case 'manifest_read_failed':
      return hasExactKeys(value, ['code', 'detail']) && isString(value.detail)
    case 'manifest_empty':
      return hasExactKeys(value, ['code'])
    case 'manifest_invalid_json':
    case 'manifest_invalid_row':
      return hasExactKeys(value, ['code', 'line_number', 'detail'])
        && isPositiveInteger(value.line_number)
        && isString(value.detail)
    case 'manifest_identity_mismatch':
      return hasExactKeys(value, [
        'code', 'line_number', 'observed_keeper', 'observed_trace',
      ])
        && isPositiveInteger(value.line_number)
        && isString(value.observed_keeper)
        && isString(value.observed_trace)
    default:
      return false
  }
}

function isOwnerGap(gap: Record<string, unknown>): boolean {
  if (!isString(gap.code)) return false
  switch (gap.code) {
    case 'keeper_catalog_unavailable':
      return hasExactKeys(gap, ['code', 'detail']) && isString(gap.detail)
    case 'keeper_catalog_changed_during_resolution':
      return hasExactKeys(gap, ['code'])
    case 'invalid_persisted_keeper_name':
      return hasExactKeys(gap, ['code', 'keeper']) && isString(gap.keeper)
    case 'keeper_meta_name_mismatch':
      return hasExactKeys(gap, ['code', 'keeper', 'metadata_name'])
        && isString(gap.keeper)
        && isString(gap.metadata_name)
    case 'keeper_meta_unavailable':
      return hasExactKeys(gap, ['code', 'keeper', 'detail'])
        && isString(gap.keeper)
        && isString(gap.detail)
    case 'runtime_manifest_unreadable':
      return hasExactKeys(gap, ['code', 'keeper', 'cause'])
        && isString(gap.keeper)
        && isManifestCause(gap.cause)
    default:
      return false
  }
}

function isActivationGap(gap: Record<string, unknown>): boolean {
  if (!isString(gap.code)) return false
  switch (gap.code) {
    case 'trace_root_unavailable':
    case 'trace_entry_unreadable':
      return isFilesystemGap(gap, gap.code)
    case 'trace_root_not_directory':
      return hasExactKeys(gap, ['code', 'kind'])
        && isString(gap.kind)
        && fileKinds.has(gap.kind)
    case 'invalid_trace_directory':
    case 'symlink_trace_entry':
      return hasExactKeys(gap, ['code', 'entry']) && isString(gap.entry)
    case 'trace_entry_not_directory':
      return hasExactKeys(gap, ['code', 'trace_id', 'kind'])
        && isString(gap.trace_id)
        && isString(gap.kind)
        && fileKinds.has(gap.kind)
    case 'trace_inventory_changed_during_discovery':
    case 'trace_root_changed_during_discovery':
      return hasExactKeys(gap, ['code'])
    case 'ledger_changed_during_discovery':
      return hasExactKeys(gap, ['code', 'trace_id']) && isString(gap.trace_id)
    case 'ledger_unreadable':
      return hasExactKeys(gap, ['code', 'trace_id', 'cause_code', 'detail'])
        && isString(gap.trace_id)
        && isString(gap.cause_code)
        && isString(gap.detail)
    default:
      return false
  }
}

function isLowerHexRevision(value: string): boolean {
  if (value.length !== 64) return false
  for (const character of value) {
    if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))) {
      return false
    }
  }
  return true
}

interface Rfc3339Instant {
  value: number
}

function parseStrictRfc3339(value: string): Rfc3339Instant | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value)
  if (match === null) return null
  const [, yearText, monthText, dayText, hourText, minuteText, secondText,
    fractionText = '', zone, sign, offsetHourText = '0', offsetMinuteText = '0'] = match
  const year = Number(yearText)
  const month = Number(monthText)
  const day = Number(dayText)
  const hour = Number(hourText)
  const minute = Number(minuteText)
  const second = Number(secondText)
  const offsetHour = Number(offsetHourText)
  const offsetMinute = Number(offsetMinuteText)
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 60
    || offsetHour > 23 || offsetMinute > 59) return null
  const monthBoundary = new Date(0)
  monthBoundary.setUTCFullYear(year, month, 0)
  const daysInMonth = monthBoundary.getUTCDate()
  if (day < 1 || day > daysInMonth) return null
  const civil = new Date(0)
  civil.setUTCFullYear(year, month - 1, day)
  civil.setUTCHours(hour, minute, second, 0)
  const offset = zone === 'Z'
    ? 0
    : (offsetHour * 60 + offsetMinute) * (sign === '+' ? 60 : -60)
  const wholeSeconds = civil.getTime() / 1000 - offset
  const minimum = new Date(0)
  minimum.setUTCFullYear(0, 0, 1)
  minimum.setUTCHours(0, 0, 0, 0)
  const maximumExclusive = new Date(0)
  maximumExclusive.setUTCFullYear(10_000, 0, 1)
  maximumExclusive.setUTCHours(0, 0, 0, 0)
  if (wholeSeconds < minimum.getTime() / 1000
    || wholeSeconds >= maximumExclusive.getTime() / 1000) return null
  const ptimeFraction = fractionText.slice(0, 12)
  const instant = wholeSeconds
    + (ptimeFraction === '' ? 0 : Number(`0.${ptimeFraction}`))
  return { value: instant }
}

function compareRfc3339(left: Rfc3339Instant, right: Rfc3339Instant): number {
  return left.value === right.value ? 0 : left.value < right.value ? -1 : 1
}

function sameRfc3339Instant(left: string, right: string): boolean {
  const leftInstant = parseStrictRfc3339(left)
  const rightInstant = parseStrictRfc3339(right)
  return leftInstant !== null && rightInstant !== null
    && compareRfc3339(leftInstant, rightInstant) === 0
}

function turnRefBelongsToTrace(turnRef: string, traceId: string): boolean {
  const separator = turnRef.lastIndexOf('#')
  if (separator <= 0) return false
  const turnText = turnRef.slice(separator + 1)
  if (!/^[0-9]+$/.test(turnText)) return false
  const absoluteTurn = Number(turnText)
  return turnRef.slice(0, separator) === traceId
    && Number.isSafeInteger(absoluteTurn)
    && absoluteTurn > 0
}

function isPortableName(value: string): boolean {
  return value !== '.' && value !== '..' && /^[A-Za-z0-9._-]+$/.test(value)
}

function isCanonicalSkillName(value: string): boolean {
  const canonical = value.trim().normalize('NFKC')
  const scalars = [...canonical]
  return value === canonical
    && scalars.length > 0
    && scalars.length <= 64
    && !canonical.startsWith('-')
    && !canonical.endsWith('-')
    && !canonical.includes('--')
    && /^[\p{Alphabetic}\p{Number}-]+$/u.test(canonical)
    && canonical.toLowerCase() === canonical
}

function skillReferenceIdentityIsValid(identity: SkillIdentity): boolean {
  return isPortableName(identity.source_id)
    && identity.package_id !== '.'
    && identity.package_id !== '..'
    && identity.package_id !== ''
    && !identity.package_id.includes('/')
    && !identity.package_id.includes('\\')
    && !identity.package_id.includes('\0')
}

function skillIdentityIsValid(identity: SkillIdentity): boolean {
  return skillReferenceIdentityIsValid(identity) && isCanonicalSkillName(identity.name)
}

function isTaskId(value: string): boolean {
  return value.length > 0 && value.length <= 128 && /^[A-Za-z0-9_:-]+$/.test(value)
}

function hasUniqueStrings(values: readonly string[]): boolean {
  return new Set(values).size === values.length
}

function isSkillResourcePath(value: string): boolean {
  return value !== ''
    && !value.startsWith('/')
    && !value.includes('\\')
    && !value.includes('\0')
    && value.split('/').every(segment => segment !== '' && segment !== '.' && segment !== '..')
}

type SkillActionPayload = Schema.Schema.Type<typeof SkillActionSchema>
type SkillActivationPayload = Schema.Schema.Type<typeof SkillActivationPayloadSchema>

function actionIdentityKey(action: SkillActionPayload): string {
  return JSON.stringify(action.identity)
}

function actionIdentityIsValid(action: SkillActionPayload): boolean {
  return action.identity.kind === 'call_id'
    ? action.identity.call_id.trim() !== ''
    : action.identity.conversation_id.trim() !== '' && action.identity.step_index >= 0
}

function activationPayloadIsValid(
  activation: SkillActivationPayload,
  traceId: string,
): boolean {
  const activatedAt = parseStrictRfc3339(activation.activated_at)
  const origin = activation.invocation.origin
  const taskIds = origin.kind === 'task_instruction' || origin.kind === 'task_composition'
    ? origin.task_ids
    : []
  const served = activation.invocation.kind === 'instruction'
    ? activation.invocation.served_content
    : null
  const invocationValid = activation.invocation.kind === 'composition'
    ? isPortableName(activation.invocation.tool_name)
    : isLowerHexRevision(served!.sha256)
      && (served!.kind === 'skill_body' || isSkillResourcePath(served!.relative_path))
  const actionKeys = activation.actions.map(actionIdentityKey)
  const deliveryTurn = activation.delivery?.boundary.agent_core_turn
  const deliveryValid = activation.delivery === null
    ? activation.actions.length === 0
    : isLowerHexRevision(activation.delivery.content_sha256)
      && activation.delivery.runtime_id.trim() !== ''
      && parseStrictRfc3339(activation.delivery.delivered_at) !== null
      && deliveryTurn !== undefined
      && (activation.delivery.boundary.kind === 'model_response'
        ? deliveryTurn > activation.agent_core_turn
        : deliveryTurn >= activation.agent_core_turn)
      && activation.actions.every(action => action.agent_core_turn >= deliveryTurn
        && actionIdentityIsValid(action)
        && action.runtime_id.trim() !== ''
        && isPortableName(action.tool_name)
        && parseStrictRfc3339(action.observed_at) !== null)
  return isLowerHexRevision(activation.content_revision)
    && isLowerHexRevision(activation.snapshot_revision)
    && skillIdentityIsValid(activation.identity)
    && activatedAt !== null
    && traceId.length <= 64
    && /^[A-Za-z0-9_-]+$/.test(traceId)
    && turnRefBelongsToTrace(activation.turn_ref, traceId)
    && activation.runtime_id.trim() !== ''
    && activation.skill_tool_use_id.trim() !== ''
    && taskIds.every(isTaskId)
    && hasUniqueStrings(taskIds)
    && invocationValid
    && hasUniqueStrings(actionKeys)
    && deliveryValid
}

export function decodeSkillEvidenceResponse(raw: unknown): SkillEvidenceResponse {
  const decoded = decodeWithSchema(SkillEvidenceResponseSchema, raw, 'invalid_response')
  if (!skillReferenceIdentityIsValid(decoded.reference.identity)
    || !isLowerHexRevision(decoded.reference.content_revision)) {
    contractError('invalid_response', 'skill evidence reference is invalid')
  }
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
    if (!gaps.every(isOwnerGap)) {
      contractError('invalid_response', 'activation owner carries an invalid typed gap')
    }
    const activation = evidence.activation
    if (activation.identity.source_id !== decoded.reference.identity.source_id
      || activation.identity.package_id !== decoded.reference.identity.package_id
      || activation.identity.name !== decoded.reference.identity.name
      || evidence.activation.content_revision !== decoded.reference.content_revision) {
      contractError('invalid_response', 'activation reference disagrees with evidence envelope')
    }
    if (!activationPayloadIsValid(activation, evidence.trace_id)) {
      contractError('invalid_response', 'activation payload violates typed occurrence invariants')
    }
    ownerGapCount += gaps.length
  }
  if (decoded.activation?.selection === 'most_recent_observed_timestamp_tie') {
    const traces = new Set(activationEvidence.map(evidence => evidence.trace_id))
    const firstTimestamp = activationEvidence[0]?.activation.activated_at
    const sameInstant = firstTimestamp !== undefined
      && activationEvidence.every(evidence =>
        sameRfc3339Instant(firstTimestamp, evidence.activation.activated_at))
    if (traces.size !== activationEvidence.length || !sameInstant) {
      contractError('invalid_response', 'activation timestamp tie is inconsistent')
    }
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
      && decoded.coverage.composition_unavailable.length === 0
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
    && coverage.activation_gaps.every(isActivationGap)
    && activationEvidence.length <= coverage.activation_ledgers_loaded
    && (coverage.activation_scope === 'complete_retained_trace_snapshot'
      ? coverage.activation_gaps.length === 0
      : coverage.activation_scope === 'trace_store_unavailable'
        ? coverage.activation_gaps.length === 1
          && (coverage.activation_gaps[0]?.code === 'trace_root_unavailable'
            || coverage.activation_gaps[0]?.code === 'trace_root_not_directory')
          && decoded.activation === null
          && coverage.activation_sessions_inspected === 0
          && coverage.activation_ledgers_loaded === 0
          && coverage.activation_owner_gap_count === 0
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

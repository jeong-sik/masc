// MASC Dashboard — Skills catalog REST client.
//
// Reads /api/v1/skills: the published workspace skill snapshot
// (masc.skill-snapshot/v1, lib/skill_snapshot) plus the optional exact
// parser-derived surface of each effective Skill.

import { Either, ParseResult, Schema } from 'effect'
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
  shadows: readonly { winner: SkillIdentity; shadowed: SkillIdentity }[]
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

export type SkillIo =
  | { kind: 'model_orchestrated' }
  | {
    kind: 'composition'
    input_schema: Readonly<Record<string, unknown>>
    exports: readonly { name: string; node_id: string; pointer: string }[]
  }

export interface SkillProfile {
  reference: SkillReference
  kind: string
  activation_tool: string
  execution: string
  io: SkillIo
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

export interface WritableSkillSource { source_id: string }

export interface SkillCreateInput {
  kind: 'instruction' | 'composition'
  source_id: string
  package_id: string
  source_text: string
}

export interface SkillAuthoringTool {
  name: string
  description: string
  input_schema: unknown
  output: { kind: 'opaque' } | { kind: 'json'; schema: unknown }
  execution: 'serial' | 'concurrent' | 'terminal'
}

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
  request_context: Record<string, unknown> | null
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
      // Keeper_msg_async.entry_to_json writes the field on every row: the
      // submitter's JSON object, or null when none was given.
      request_context: Schema.NullOr(UnknownRecordSchema),
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
  io: Schema.Union(
    Schema.Struct({ kind: Schema.Literal('model_orchestrated') }),
    Schema.Struct({
      kind: Schema.Literal('composition'),
      input_schema: UnknownRecordSchema,
      exports: Schema.Array(Schema.Struct({
        name: Schema.NonEmptyString,
        node_id: Schema.NonEmptyString,
        pointer: Schema.String,
      })),
    }),
  ),
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

const SkillAuthoringToolsSchema = Schema.Struct({
  schema: Schema.Literal('masc.skill-authoring-tools/v1'),
  tools: Schema.Array(Schema.Struct({
    name: Schema.NonEmptyString,
    description: Schema.String,
    input_schema: Schema.Record({ key: Schema.String, value: Schema.Unknown }),
    output: Schema.Union(
      Schema.Struct({ kind: Schema.Literal('opaque') }),
      Schema.Struct({ kind: Schema.Literal('json'), schema: Schema.Record({ key: Schema.String, value: Schema.Unknown }) }),
    ),
    execution: Schema.Literal('serial', 'concurrent', 'terminal'),
  })),
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

const SkillSurfaceSchema = Schema.Union(
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('instruction'),
    diagnostics: OptionalDiagnosticsSchema,
    profile: SkillSurfaceProfileSchema,
  }),
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('composition'),
    diagnostics: OptionalDiagnosticsSchema,
    profile: SkillSurfaceProfileSchema,
  }),
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('unavailable'),
    error: Schema.NonEmptyString,
    diagnostics: OptionalDiagnosticsSchema,
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
  Schema.Struct({ kind: Schema.Literal('extension'), name: Schema.String }),
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
    key: Schema.String,
  }),
  Schema.Struct({
    ...diagnosticBase('unexpected_frontmatter_field'),
    field: Schema.String,
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
    key: Schema.String,
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
  shadows: Schema.Array(Schema.Struct({
    winner: SkillIdentitySchema,
    shadowed: SkillIdentitySchema,
  })),
  rejections: Schema.Array(SkillSnapshotRejectionSchema),
})

const ReadySkillsResponseSchema = Schema.Struct({
  schema: Schema.Literal('masc.skill-snapshot/v1'),
  state: Schema.Literal('ready'),
  snapshot: SkillSnapshotSchema,
  surfaces: Schema.Array(SkillSurfaceSchema),
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
  for (const { winner, shadowed } of decoded.snapshot.shadows) {
    if (winner.name !== shadowed.name
      || (winner.source_id === shadowed.source_id && winner.package_id === shadowed.package_id)) {
      contractError('invalid_response', 'a shadow must pair distinct identities declaring the same name')
    }
  }
  validateSurfaceCoverage(decoded.snapshot, decoded.surfaces)
  return decoded
}

export async function fetchSkills(opts: GetOptions = {}): Promise<SkillsResponse> {
  const raw = await get<unknown>('/api/v1/skills', opts)
  return decodeSkillsResponse(raw)
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

export function decodeExactSkillReference(raw: unknown): SkillReference {
  const reference = decodeWithSchema(SkillReferenceSchema, raw, 'invalid_response')
  if (!skillIdentityIsValid(reference.identity) || !isLowerHexRevision(reference.content_revision)) {
    contractError('invalid_response', 'invalid exact Skill reference')
  }
  return reference
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

export async function fetchSkillAuthoringTools(): Promise<readonly SkillAuthoringTool[]> {
  return decodeWithSchema(SkillAuthoringToolsSchema,
    await get<unknown>('/api/v1/skills/editor/tools'), 'invalid_response').tools
}

export async function previewNewSkillSource(input: SkillCreateInput): Promise<SkillEditorPreview> {
  return decodeSkillEditorPreview(
    await post<unknown>('/api/v1/skills/editor/preview-new', input),
  )
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
 * answers exactly created_and_published, created_but_shadowed (with the
 * earlier source's package that holds the name, which Keepers see instead)
 * or created_but_unpublished (with the reason). Anything else is drift, not
 * a state to invent a label for — the old `?? 'created'` default reported a
 * status the server never sends and hid the not-published reason. */
export type SkillCreateReceipt =
  | { status: 'created_and_published' }
  | { status: 'created_but_shadowed'; winner: SkillIdentity }
  | { status: 'created_but_unpublished'; reason: string }

export function decodeSkillCreateReceipt(raw: unknown): SkillCreateReceipt {
  if (typeof raw === 'object' && raw !== null) {
    const record = raw as Record<string, unknown>
    if (record.status === 'created_and_published') {
      return { status: 'created_and_published' }
    }
    if (record.status === 'created_but_shadowed') {
      const winner = Schema.decodeUnknownEither(
        SkillIdentitySchema,
        STRICT_PARSE_OPTIONS,
      )(record.winner)
      if (Either.isRight(winner)) {
        return { status: 'created_but_shadowed', winner: winner.right }
      }
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

export async function createSkill(input: SkillCreateInput): Promise<SkillCreateReceipt> {
  return decodeSkillCreateReceipt(
    await postControlPlane<unknown>('/api/v1/skills/editor/create', input),
  )
}

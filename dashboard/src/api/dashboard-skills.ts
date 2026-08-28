// MASC Dashboard — Skills catalog REST client.
//
// Reads /api/v1/skills: the published workspace skill snapshot
// (masc.skill-snapshot/v1, lib/skill_snapshot) plus the optional exact
// parser-derived surface of each effective Skill.

import { Either, ParseResult, Schema } from 'effect'
import { get, post, type GetOptions } from './core'

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

export interface SkillEvidenceCoverage {
  composition_scan_limit: number
  composition_rows_scanned: number
  instruction_ledgers_loaded: number
  unavailable: readonly string[]
}

export interface SkillActivationEvidence {
  keeper: string
  activation: Record<string, unknown>
}

export interface SkillCompositionEvidence {
  run: Record<string, unknown>
  nodes: readonly Record<string, unknown>[]
}

export interface SkillEvidenceResponse {
  schema: 'masc.skill-evidence/v1'
  status: 'observed' | 'never_observed'
  reference: SkillReference
  activation: SkillActivationEvidence | null
  composition: SkillCompositionEvidence | null
  coverage: SkillEvidenceCoverage
}

export interface WritableSkillSource { source_id: string }

interface SkillSurfaceBase {
  reference: SkillReference
  diagnostics?: readonly string[]
  profile?: SkillProfile | null
  usage?: readonly SkillUsage[]
}

export type SkillSurface =
  | (SkillSurfaceBase & { kind: 'instruction' })
  | (SkillSurfaceBase & {
      kind: 'composition'
      tool_name: string
      execution: string
    })
  | (SkillSurfaceBase & { kind: 'unavailable'; error: string })

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

const SkillEvidenceResponseSchema = Schema.Struct({
  schema: Schema.Literal('masc.skill-evidence/v1'),
  status: Schema.Literal('observed', 'never_observed'),
  reference: SkillReferenceSchema,
  activation: Schema.NullOr(Schema.Struct({
    keeper: Schema.NonEmptyString,
    activation: UnknownRecordSchema,
  })),
  composition: Schema.NullOr(Schema.Struct({
    run: UnknownRecordSchema,
    nodes: Schema.Array(UnknownRecordSchema),
  })),
  coverage: Schema.Struct({
    composition_scan_limit: PositiveSafeIntegerSchema,
    composition_rows_scanned: NonNegativeSafeIntegerSchema,
    instruction_ledgers_loaded: NonNegativeSafeIntegerSchema,
    unavailable: Schema.Array(Schema.String),
  }),
})

const SkillProfileSchema = Schema.Struct({
  reference: SkillReferenceSchema,
  kind: Schema.NonEmptyString,
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
})

const OptionalProfileSchema = Schema.optional(Schema.NullOr(SkillProfileSchema))
const OptionalUsageSchema = Schema.optional(Schema.Array(SkillUsageSchema))

const SkillSurfaceSchema = Schema.Union(
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('instruction'),
    diagnostics: OptionalDiagnosticsSchema,
    profile: OptionalProfileSchema,
    usage: OptionalUsageSchema,
  }),
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('composition'),
    tool_name: Schema.NonEmptyString,
    execution: Schema.NonEmptyString,
    diagnostics: OptionalDiagnosticsSchema,
    profile: OptionalProfileSchema,
    usage: OptionalUsageSchema,
  }),
  Schema.Struct({
    reference: SkillReferenceSchema,
    kind: Schema.Literal('unavailable'),
    error: Schema.NonEmptyString,
    diagnostics: OptionalDiagnosticsSchema,
    profile: OptionalProfileSchema,
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
  return decoded
}

export async function fetchSkillEvidence(reference: SkillReference): Promise<SkillEvidenceResponse> {
  const raw = await post<unknown>('/api/v1/skills/evidence', { reference })
  return decodeSkillEvidenceResponse(raw)
}

export async function fetchWritableSkillSources(): Promise<readonly WritableSkillSource[]> {
  const response = await get<{ status: string; sources: readonly WritableSkillSource[] }>(
    '/api/v1/skills/editor/sources',
  )
  return response.sources
}

export async function createSkill(input: {
  source_id: string
  package_id: string
  source_text: string
}): Promise<Record<string, unknown>> {
  return post('/api/v1/skills/editor/create', input)
}

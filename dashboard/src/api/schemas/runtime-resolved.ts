// Resolved runtime schema — schema-at-boundary for `GET /api/v1/runtime/resolved`.
//
// Bugs #14/#15/#36: the dashboard previously derived "what runtime/model is
// applied" from divergent projections (a raw runtime.toml re-parse, the
// assignments-only /api/v1/dashboard/runtime-defaults listing, and a
// hand-rolled fallback that faked runtime-provider catalog fields from that
// listing). This is the single resolved document instead: effective
// max-context plus which of override/capability/override_clamped_by_capability
// produced it (see lib/runtime/runtime.mli `resolve_max_context_of_runtime`),
// every configured lane, and the full keeper fleet joined against
// [runtime.assignments] with the [runtime].default rider made explicit
// (assignment_source: "explicit" | "default"). No fabricated defaults: an
// unresolved runtime config surfaces null/[] rather than a synthesized value.

import {
  array,
  boolean,
  literal,
  nullable,
  number,
  object,
  optional,
  string,
  union,
  type BaseIssue,
  type InferOutput,
} from 'valibot'
import { parseOrThrow, SchemaDriftError } from './drift-error'

const MaxContextSourceSchema = union([
  literal('override'),
  literal('capability'),
  literal('override_clamped_by_capability'),
])

const RuntimeResolutionSchema = object({
  id: string(),
  provider: string(),
  model: string(),
  effective_max_context: nullable(number()),
  max_context_source: nullable(MaxContextSourceSchema),
  max_output_tokens: nullable(number()),
  is_local: boolean(),
  is_default: boolean(),
})

const RuntimeLaneSchema = object({
  id: string(),
  runtime_ids: array(string()),
})

const ResolvedAssignmentTargetSchema = object({
  kind: union([literal('lane'), literal('single_runtime'), literal('missing')]),
  id: nullable(string()),
})

const RuntimeAssignmentSchema = object({
  keeper: string(),
  assignment_source: union([literal('explicit'), literal('default')]),
  resolved: ResolvedAssignmentTargetSchema,
})

const RuntimeResolvedResponseSchema = object({
  generated_at_iso: optional(string()),
  source: optional(string()),
  config_path: nullable(string()),
  default_runtime: nullable(RuntimeResolutionSchema),
  runtimes: array(RuntimeResolutionSchema),
  lanes: array(RuntimeLaneSchema),
  assignments: array(RuntimeAssignmentSchema),
})

export type MaxContextSource = InferOutput<typeof MaxContextSourceSchema>
export type RuntimeResolution = InferOutput<typeof RuntimeResolutionSchema>
export type RuntimeLaneSnapshot = InferOutput<typeof RuntimeLaneSchema>
export type ResolvedAssignmentTarget = InferOutput<typeof ResolvedAssignmentTargetSchema>
export type RuntimeAssignment = InferOutput<typeof RuntimeAssignmentSchema>
export type RuntimeResolvedResponse = InferOutput<typeof RuntimeResolvedResponseSchema>

export class RuntimeResolvedSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('runtime_resolved', issues)
  }
}

export function parseRuntimeResolvedResponse(data: unknown): RuntimeResolvedResponse {
  return parseOrThrow(RuntimeResolvedSchemaDriftError, RuntimeResolvedResponseSchema, data)
}

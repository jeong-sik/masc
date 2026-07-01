// Runtime defaults / model routing schema — schema-at-boundary for
// `GET /api/v1/dashboard/runtime-defaults`.
//
// The backend serves the ALREADY-RESOLVED runtime config (runtime.toml SSOT,
// populated by Runtime.init_default) — see
// lib/server/server_dashboard_runtime_defaults_json.ml. The frontend consumes
// this structured projection instead of re-parsing the raw TOML exposed by
// /api/v1/runtime/config/raw. Unresolved config surfaces null/[] (no fabricated
// defaults), so every cursor-like field is nullable rather than defaulted.

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'
import { parseOrThrow, SchemaDriftError } from './drift-error'

const RuntimeEntrySchema = object({
  id: string(),
  provider: string(),
  model: string(),
  max_context: number(),
  is_default: boolean(),
})

const KeeperAssignmentSchema = object({
  keeper: string(),
  runtime_id: string(),
})

const ModelRoutingSchema = object({
  keeper_assignments: array(KeeperAssignmentSchema),
  librarian_runtime_id: nullable(string()),
  structured_judge_runtime_id: nullable(string()),
  cross_verifier_runtime_id: nullable(string()),
  media_failover: array(string()),
})

const RuntimeDefaultsResponseSchema = object({
  generated_at_iso: optional(string()),
  dashboard_surface: optional(string()),
  source: optional(string()),
  config_path: nullable(string()),
  default_runtime_id: nullable(string()),
  default_model: nullable(string()),
  default_max_context: nullable(number()),
  runtimes: array(RuntimeEntrySchema),
  model_routing: ModelRoutingSchema,
})

export type RuntimeEntry = InferOutput<typeof RuntimeEntrySchema>
export type KeeperAssignment = InferOutput<typeof KeeperAssignmentSchema>
export type ModelRouting = InferOutput<typeof ModelRoutingSchema>
export type RuntimeDefaultsResponse = InferOutput<typeof RuntimeDefaultsResponseSchema>

export class RuntimeDefaultsSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('runtime_defaults', issues)
  }
}

export function parseRuntimeDefaultsResponse(data: unknown): RuntimeDefaultsResponse {
  return parseOrThrow(RuntimeDefaultsSchemaDriftError, RuntimeDefaultsResponseSchema, data)
}

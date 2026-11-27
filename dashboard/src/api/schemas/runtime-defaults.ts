// Runtime defaults / model routing schema — schema-at-boundary for
// `GET /api/v1/dashboard/runtime-defaults`.
//
// The backend serves the ALREADY-RESOLVED runtime config (runtime.toml SSOT,
// populated by Runtime.init_default) — see
// lib/server/server_dashboard_runtime_defaults_json.ml. Unresolved config
// surfaces null/[] (no fabricated defaults), so every cursor-like field is
// nullable rather than defaulted.

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

const RuntimeMediaCapabilitiesSchema = object({
  supports_image_input: optional(boolean()),
  supports_image_output: optional(boolean()),
  vision_input: optional(boolean()),
  image_output: optional(boolean()),
})

const RuntimeEntrySchema = object({
  id: string(),
  provider: string(),
  model: string(),
  max_context: number(),
  is_default: boolean(),
  capabilities: optional(nullable(RuntimeMediaCapabilitiesSchema)),
  supports_image_input: optional(boolean()),
  supports_image_output: optional(boolean()),
})

const RuntimeMediaOverridesSchema = object({
  vision_reader: optional(nullable(string())),
  image_generator: optional(nullable(string())),
})

const ModelRoutingSchema = object({
  media: optional(nullable(RuntimeMediaOverridesSchema)),
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
  media: optional(nullable(RuntimeMediaOverridesSchema)),
})

export type RuntimeEntry = InferOutput<typeof RuntimeEntrySchema>
export type RuntimeMediaOverrides = InferOutput<typeof RuntimeMediaOverridesSchema>
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

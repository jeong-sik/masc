// Cascade dashboard schemas — schema-at-boundary for
// `/api/v1/cascade/{config,config/raw,health}`.
//
// These endpoints drive operational UI state, so missing required
// fields are treated as backend/frontend contract drift. Optional
// additive fields stay optional to preserve compatibility with older
// servers.

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  picklist,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

const CascadeInvalidProfileSchema = object({
  name: string(),
  errors: array(string()),
})

export type CascadeInvalidProfile = InferOutput<typeof CascadeInvalidProfileSchema>

const CascadeCandidateSchema = object({
  model: string(),
  display_model: optional(nullable(string())),
  provider_name: optional(nullable(string())),
  display_provider_name: optional(nullable(string())),
  runtime_kind: optional(nullable(string())),
  expanded_models: optional(nullable(array(string()))),
  config_weight: number(),
  effective_weight: number(),
  success_rate: number(),
  in_cooldown: boolean(),
})

export type CascadeCandidate = InferOutput<typeof CascadeCandidateSchema>

const CascadeProfileSourceSchema = picklist([
  'named',
  'default_fallback',
  'hardcoded_defaults',
  'load_failed',
])

const CascadeProfileSchema = object({
  name: string(),
  source: CascadeProfileSourceSchema,
  keeper_assignable: boolean(),
  candidates: array(CascadeCandidateSchema),
})

export type CascadeProfile = InferOutput<typeof CascadeProfileSchema>

const CascadeKeeperProfileSchema = object({
  keeper: string(),
  cascade_name: string(),
  canonical: string(),
})

export type CascadeKeeperProfile = InferOutput<typeof CascadeKeeperProfileSchema>

const CascadeValidationStatusSchema = picklist([
  'validated',
  'serving_valid_subset',
  'serving_last_known_good',
  'invalid',
])

export type CascadeValidationStatus = InferOutput<typeof CascadeValidationStatusSchema>

const CascadeConfigResponseSchema = object({
  updated_at: string(),
  source_path: string(),
  validation_status: CascadeValidationStatusSchema,
  validation_errors: array(string()),
  invalid_profiles: array(CascadeInvalidProfileSchema),
  profiles: array(CascadeProfileSchema),
  keeper_profiles: array(CascadeKeeperProfileSchema),
})

export type CascadeConfigResponse = InferOutput<typeof CascadeConfigResponseSchema>

const CascadeRawConfigResponseSchema = object({
  updated_at: string(),
  source_path: string(),
  source_editable: boolean(),
  source_text: string(),
})

export type CascadeRawConfigResponse = InferOutput<typeof CascadeRawConfigResponseSchema>

const CascadeProviderStatusSchema = picklist(['active', 'cooldown', 'configured'])

export type CascadeProviderStatus = InferOutput<typeof CascadeProviderStatusSchema>

const CascadeHealthProviderSchema = object({
  provider_key: string(),
  success_rate: number(),
  consecutive_failures: number(),
  in_cooldown: boolean(),
  cooldown_expires_at: nullable(number()),
  events_in_window: number(),
  rejected_in_window: optional(number()),
  declared: optional(boolean()),
  status: optional(CascadeProviderStatusSchema),
  avg_prompt_tok_per_sec: optional(nullable(number())),
  avg_decode_tok_per_sec: optional(nullable(number())),
  avg_tok_per_sec: optional(nullable(number())),
  avg_latency_ms: optional(nullable(number())),
  p50_latency_ms: optional(nullable(number())),
  p95_latency_ms: optional(nullable(number())),
  request_count: optional(nullable(number())),
})

export type CascadeHealthProvider = InferOutput<typeof CascadeHealthProviderSchema>

const CascadeHealthResponseSchema = object({
  updated_at: string(),
  window_sec: number(),
  cooldown_threshold: number(),
  cooldown_sec: number(),
  hard_quota_cooldown_sec: number(),
  providers: array(CascadeHealthProviderSchema),
  perf_window_minutes: optional(nullable(number())),
})

export type CascadeHealthResponse = InferOutput<typeof CascadeHealthResponseSchema>

export class CascadeSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('cascade', issues)
  }
}

export function parseCascadeConfigResponse(data: unknown): CascadeConfigResponse {
  return parseOrThrow(CascadeSchemaDriftError, CascadeConfigResponseSchema, data)
}

export function parseCascadeRawConfigResponse(data: unknown): CascadeRawConfigResponse {
  return parseOrThrow(CascadeSchemaDriftError, CascadeRawConfigResponseSchema, data)
}

export function parseCascadeHealthResponse(data: unknown): CascadeHealthResponse {
  return parseOrThrow(CascadeSchemaDriftError, CascadeHealthResponseSchema, data)
}

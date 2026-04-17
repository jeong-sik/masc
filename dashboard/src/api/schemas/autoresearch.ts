/**
 * Autoresearch API schemas — schema-at-boundary for
 * `/api/v1/autoresearch/loops` and `/api/v1/autoresearch/loops/:id`.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - TS types are derived via `InferOutput<typeof Schema>` — no hand-typed
 *   interface for these endpoints.
 * - `fetchAutoresearchLoops` / `fetchAutoresearchLoopDetail` pass raw
 *   responses through `parseAutoresearchLoopsResponse` /
 *   `parseAutoresearchLoopDetail`. Shape drift from the backend
 *   (`autoresearch_serde.ml`) raises `AutoresearchSchemaDriftError`, not
 *   `undefined` access downstream.
 * - Action endpoints (`retry` / `delete` / `start`) accept partial
 *   responses and parse through `parseAutoresearchLoopActionResponse`.
 *
 * Rolled out as part of #7441 (P2 rollout) following the pilot #7439.
 */

import {
  array,
  boolean,
  fallback,
  nullable,
  number,
  object,
  optional,
  picklist,
  safeParse,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

// Loop status evolves on the backend (new terminal states may ship
// ahead of the dashboard). Unknown values fall back to `'error'` — the
// safest visible state for an unrecognized lifecycle value (operators
// see "something went wrong" rather than an empty or healthy badge).
const AutoresearchLoopStatusSchema = fallback(
  picklist(['running', 'completed', 'stopped', 'error']),
  'error',
)

const AutoresearchCycleDecisionSchema = fallback(
  picklist(['keep', 'discard']),
  'discard',
)

export const AutoresearchCycleRecordSchema = object({
  cycle: number(),
  hypothesis: string(),
  score_before: number(),
  score_after: number(),
  delta: number(),
  decision: AutoresearchCycleDecisionSchema,
  commit_hash: nullable(string()),
  elapsed_ms: number(),
  model_used: string(),
  timestamp: number(),
})

export const AutoresearchLoopSummarySchema = object({
  loop_id: string(),
  author: nullable(string()),
  goal: string(),
  metric_fn: string(),
  model_model: string(),
  target_file: string(),
  status: AutoresearchLoopStatusSchema,
  current_cycle: number(),
  max_cycles: number(),
  baseline: number(),
  best_score: number(),
  best_cycle: number(),
  total_keeps: number(),
  total_discards: number(),
  elapsed_s: number(),
  updated_at: nullable(number()),
  // The backend sometimes omits `live` on just-started loops; default
  // to `false` rather than drifting into "is live" on an absent field.
  live: fallback(boolean(), false),
  workdir: string(),
  source_workdir: string(),
  program_note: nullable(string()),
  warnings: array(string()),
  insights: array(string()),
  recent_cycles: array(AutoresearchCycleRecordSchema),
  error: nullable(string()),
  session_id: nullable(string()),
  operation_id: nullable(string()),
  linked_at: nullable(number()),
  queued_hypothesis: nullable(string()),
})

export const AutoresearchLoopsResponseSchema = object({
  loops: array(AutoresearchLoopSummarySchema),
  total: number(),
})

export const AutoresearchLoopDetailSchema = object({
  ...AutoresearchLoopSummarySchema.entries,
  history: array(AutoresearchCycleRecordSchema),
  history_count: number(),
})

// Action responses are heterogeneous (retry/delete/start each set a
// different subset of fields). Every field past `ok` is optional on
// purpose — the backend contract documents that.
export const AutoresearchLoopActionResponseSchema = object({
  ok: fallback(boolean(), false),
  action: optional(picklist(['retry', 'delete', 'start'])),
  loop_id: optional(string()),
  loop: optional(AutoresearchLoopSummarySchema),
  error: optional(string()),
})

export type AutoresearchCycleRecord = InferOutput<typeof AutoresearchCycleRecordSchema>
export type AutoresearchLoopSummary = InferOutput<typeof AutoresearchLoopSummarySchema>
export type AutoresearchLoopsResponse = InferOutput<typeof AutoresearchLoopsResponseSchema>
export type AutoresearchLoopDetail = InferOutput<typeof AutoresearchLoopDetailSchema>
export type AutoresearchLoopActionResponse = InferOutput<typeof AutoresearchLoopActionResponseSchema>

export class AutoresearchSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(endpoint: string, issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .slice(0, 3)
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`autoresearch schema drift at ${endpoint}: ${summary}`)
    this.name = 'AutoresearchSchemaDriftError'
    this.issues = issues
  }
}

function parseOrThrow<TSchema extends Parameters<typeof safeParse>[0]>(
  endpoint: string,
  schema: TSchema,
  data: unknown,
): InferOutput<TSchema> {
  const result = safeParse(schema, data)
  if (!result.success) {
    throw new AutoresearchSchemaDriftError(endpoint, result.issues)
  }
  return result.output as InferOutput<TSchema>
}

export function parseAutoresearchLoopsResponse(data: unknown): AutoresearchLoopsResponse {
  return parseOrThrow('/api/v1/autoresearch/loops', AutoresearchLoopsResponseSchema, data)
}

export function parseAutoresearchLoopDetail(data: unknown): AutoresearchLoopDetail {
  return parseOrThrow('/api/v1/autoresearch/loops/:id', AutoresearchLoopDetailSchema, data)
}

export function parseAutoresearchLoopActionResponse(
  data: unknown,
): AutoresearchLoopActionResponse {
  return parseOrThrow(
    '/api/v1/autoresearch/loops/:action',
    AutoresearchLoopActionResponseSchema,
    data,
  )
}

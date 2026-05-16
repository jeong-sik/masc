// Provider logs schema — schema-at-boundary for
// `GET /api/v1/dashboard/provider-logs` and `/provider-logs/tail`.
//
// Paths come from cascade.toml only. The tail endpoint never accepts an
// arbitrary path from the browser.

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  record,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

const ProviderLogCatalogEntrySchema = object({
  id: string(),
  display_name: string(),
  protocol: string(),
  enabled: boolean(),
  path: optional(nullable(string())),
  resolved_path: optional(nullable(string())),
  default_lines: optional(nullable(number())),
  max_bytes: optional(nullable(number())),
  cascade_config_path: optional(string()),
})

const ProviderLogsCatalogResponseSchema = object({
  generated_at_iso: optional(string()),
  dashboard_surface: optional(string()),
  source: optional(string()),
  ok: optional(boolean()),
  error: optional(string()),
  providers: array(ProviderLogCatalogEntrySchema),
})

const ProviderLogTailLineSchema = object({
  line: number(),
  text: string(),
})

const ProviderLogProviderSchema = object({
  id: string(),
  display_name: string(),
  protocol: string(),
})

const ProviderLogTailResponseSchema = object({
  generated_at_iso: optional(string()),
  dashboard_surface: optional(string()),
  source: optional(string()),
  ok: optional(boolean()),
  error: optional(string()),
  provider: ProviderLogProviderSchema,
  log: optional(record(string(), unknown())),
  query: optional(record(string(), unknown())),
  returned: optional(number()),
  entries: array(ProviderLogTailLineSchema),
})

export type ProviderLogCatalogEntry = InferOutput<typeof ProviderLogCatalogEntrySchema>
export type ProviderLogsCatalogResponse = InferOutput<typeof ProviderLogsCatalogResponseSchema>
export type ProviderLogTailLine = InferOutput<typeof ProviderLogTailLineSchema>
export type ProviderLogTailResponse = InferOutput<typeof ProviderLogTailResponseSchema>

export class ProviderLogsSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`provider logs schema drift: ${summary}`)
    this.name = ProviderLogsSchemaDriftError.name
    this.issues = issues
  }
}

export function parseProviderLogsCatalogResponse(data: unknown): ProviderLogsCatalogResponse {
  const result = safeParse(ProviderLogsCatalogResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new ProviderLogsSchemaDriftError(result.issues)
  }
  return result.output
}

export function parseProviderLogTailResponse(data: unknown): ProviderLogTailResponse {
  const result = safeParse(ProviderLogTailResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new ProviderLogsSchemaDriftError(result.issues)
  }
  return result.output
}

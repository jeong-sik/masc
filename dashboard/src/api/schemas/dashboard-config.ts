// Dashboard config schema — schema-at-boundary for
// `GET /api/v1/dashboard/config`.
//
// The config panel renders operational truth from env/default/runtime
// provenance. Missing required fields indicate backend/frontend
// contract drift rather than a display-only absence.

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  picklist,
  record,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

const ConfigEntrySourceSchema = picklist(['env', 'default', 'derived', 'runtime'])

export type ConfigEntrySource = InferOutput<typeof ConfigEntrySourceSchema>

const ConfigEntryProvenanceSchema = object({
  kind: ConfigEntrySourceSchema,
  detail: string(),
  derived_from: optional(array(string())),
})

export type ConfigEntryProvenance = InferOutput<typeof ConfigEntryProvenanceSchema>

const ConfigEntrySchema = object({
  env: string(),
  description: string(),
  value: nullable(string()),
  default: string(),
  source: ConfigEntrySourceSchema,
  source_detail: optional(string()),
  provenance: optional(ConfigEntryProvenanceSchema),
  sensitive: boolean(),
})

export type ConfigEntry = InferOutput<typeof ConfigEntrySchema>

const DashboardConfigServerSchema = object({
  version: string(),
  git_commit: nullable(string()),
  ocaml_version: string(),
  uptime_seconds: number(),
  pid: number(),
})

const DashboardConfigResponseSchema = object({
  generated_at: string(),
  server: DashboardConfigServerSchema,
  categories: record(string(), array(ConfigEntrySchema)),
})

export type DashboardConfigResponse = InferOutput<typeof DashboardConfigResponseSchema>

export class DashboardConfigSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('dashboard-config', issues)
  }
}

export function parseDashboardConfigResponse(data: unknown): DashboardConfigResponse {
  return parseOrThrow(DashboardConfigSchemaDriftError, DashboardConfigResponseSchema, data)
}

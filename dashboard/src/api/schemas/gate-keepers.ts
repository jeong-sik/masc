// Gate keepers schema — schema-at-boundary for
// `GET /api/v1/gate/keepers`.
//
// `name` is the only required field per-entry — matches the prior
// decoder's `if (!name) return null` guard. Every other attribute is
// optional because the backend probes them lazily and a keeper with
// only name + status should still render as "exists but metadata
// pending" rather than drop off the list.
//
// Outer shape is strict-with-fallbacks; per-entry is lenient (bad
// rows drop silently so one corrupt keeper never blanks the whole
// list). Same pattern as #7768 gate-status and #7746 logs.
//
// Uses the shared `SchemaDriftError` base landed in #7732.

import {
  boolean,
  fallback,
  nullable,
  number,
  object,
  optional,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

const GateKeeperInfoSchema = object({
  name: string(),
  agent_name: optional(string()),
  status: optional(string()),
  model: optional(string()),
  active_model: optional(string()),
  primary_model: optional(string()),
  keepalive_running: optional(boolean()),
  // Original decoder: `asNumber(raw.last_turn_ago_s) ?? null`. Absent
  // field collapses to `null` (never `undefined`) so downstream renders
  // '—' uniformly.
  last_turn_ago_s: fallback(nullable(number()), null),
})

export type GateKeeperInfo = InferOutput<typeof GateKeeperInfoSchema>

const GateKeepersOuterSchema = object({
  count: fallback(number(), 0),
  keepers: optional(unknown()),
})

export interface GateKeepersData {
  count: number
  keepers: GateKeeperInfo[]
}

export class GateKeepersSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('gate-keepers', issues)
  }
}

export function parseGateKeepersData(data: unknown): GateKeepersData {
  const outer = parseOrThrow(GateKeepersSchemaDriftError, GateKeepersOuterSchema, data)
  const rawEntries = Array.isArray(outer.keepers) ? outer.keepers : []
  const keepers: GateKeeperInfo[] = []
  for (const raw of rawEntries) {
    const parsed = safeParse(GateKeeperInfoSchema, raw, { abortEarly: true })
    if (parsed.success) keepers.push(parsed.output)
  }
  return { count: outer.count, keepers }
}

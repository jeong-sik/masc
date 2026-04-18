/**
 * Activity endpoint schemas — schema-at-boundary for
 * `/api/v1/activity/graph` and `/api/v1/activity/swimlane`.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - TS types are derived via `InferOutput<typeof Schema>` — no hand-typed
 *   interfaces in `src/types/sse.ts` for these responses anymore.
 * - `fetchActivityGraph` / `fetchSwimlane` route every response through
 *   `parseActivityGraphResponse` / `parseSwimlaneResponse`. Shape drift
 *   from the backend raises `ActionsActivitySchemaDriftError`, which
 *   the callers log (`console.debug`) and translate to `null` — the
 *   pre-existing "fetch failure" contract already used by every caller
 *   of these two functions.
 *
 * Rolled out as part of #7441 (P2 rollout).
 */

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  pipe,
  record,
  safeParse,
  string,
  transform,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

// Node / edge `kind` and `status` stay open `string()`. They're
// backend-evolved enumerations (new agent kinds, new lifecycle states)
// and the dashboard renders them via a best-effort label/color lookup
// with string fallback — a strict `picklist` here would brick the
// whole graph during a backend-ahead deploy window.
const ActivityGraphNodeSchema = object({
  id: string(),
  label: string(),
  weight: number(),
  semantic_weight: optional(number()),
  kind: string(),
  status: string(),
  last_event_at: optional(string()),
  meta: optional(record(string(), unknown())),
})

const ActivityGraphEdgeSchema = object({
  id: optional(string()),
  source: string(),
  target: string(),
  kind: string(),
  weight: number(),
  active: boolean(),
  last_event_at: optional(string()),
  meta: optional(record(string(), unknown())),
})

// Timeline events are opaque to the schema layer: `actor`, `subject`,
// `payload`, `tags` are passed through to renderers that treat them as
// display-only / diagnostic. Enforcing a stricter shape would force
// the schema to track every backend event variant.
const ActivityGraphTimelineEventRawSchema = object({
  kind: string(),
  actor: optional(nullable(record(string(), unknown()))),
  summary: optional(string()),
  subject: optional(nullable(record(string(), unknown()))),
  ts: optional(number()),
  ts_ms: optional(number()),
  ts_iso: string(),
  seq: number(),
  room_id: string(),
  tags: array(string()),
  payload: record(string(), unknown()),
})

function firstString(
  source: Record<string, unknown>,
  keys: readonly string[],
): string | null {
  for (const key of keys) {
    const value = source[key]
    if (typeof value === 'string' && value.trim() !== '') return value.trim()
  }
  return null
}

function normalizeActivitySubject(
  value: Record<string, unknown> | null | undefined,
): { id: string; type: string } | null {
  if (!value) return null
  const id = typeof value.id === 'string' ? value.id.trim() : ''
  if (id === '') return null
  const type =
    (typeof value.type === 'string' && value.type.trim() !== '' ? value.type.trim() : null)
    ?? (typeof value.kind === 'string' && value.kind.trim() !== '' ? value.kind.trim() : null)
    ?? 'entity'
  return { id, type }
}

function deriveActivitySummary(
  kind: string,
  payload: Record<string, unknown>,
  subject: { id: string; type: string } | null,
): string {
  return firstString(payload, [
    'summary',
    'message',
    'content',
    'task_title',
    'title',
    'reason',
    'notes',
    'cmd',
    'tool_args_preview',
    'tool_name',
    'verification_id',
    'contract_id',
    'run_id',
    'target_id',
    'task_id',
  ])
    ?? subject?.id
    ?? kind
}

const ActivityGraphTimelineEventSchema = pipe(
  ActivityGraphTimelineEventRawSchema,
  transform((raw: InferOutput<typeof ActivityGraphTimelineEventRawSchema>) => {
    const actor = raw.actor ?? {}
    const subject = normalizeActivitySubject(raw.subject ?? null)
    const payload = raw.payload
    return {
      kind: raw.kind,
      actor,
      summary: raw.summary?.trim() || deriveActivitySummary(raw.kind, payload, subject),
      subject,
      ts: raw.ts ?? raw.ts_ms ?? Date.parse(raw.ts_iso),
      ts_iso: raw.ts_iso,
      seq: raw.seq,
      room_id: raw.room_id,
      tags: raw.tags,
      payload,
    }
  }),
)

// `stats` and `kind_counts` are open number-valued maps — the backend
// adds new counters (per-tool, per-category) without coordinating the
// dashboard release. Consumers read specific keys defensively
// (`stats.event_count ?? 0`), so an open `record` keeps new keys
// visible without churning this schema on every backend addition.
const ActivityGraphStatsSchema = record(string(), number())

const ActivityGraphKindCountsSchema = record(string(), number())

const ActivityGraphHeatmapSchema = object({
  matrix: array(array(number())),
  max: number(),
  total: number(),
})

const ActivityGraphWindowSchema = object({
  limit: number(),
  room_id: nullable(string()),
  kinds: array(string()),
})

const ActivityGraphStatsHistoryEntrySchema = object({
  bucket: number(),
  events: number(),
  active_agents: number(),
  tasks_done: number(),
})

const ActivityGraphResponseSchema = object({
  nodes: array(ActivityGraphNodeSchema),
  edges: array(ActivityGraphEdgeSchema),
  stats: ActivityGraphStatsSchema,
  kind_counts: ActivityGraphKindCountsSchema,
  heatmap: ActivityGraphHeatmapSchema,
  timeline: array(ActivityGraphTimelineEventSchema),
  generated_at: string(),
  window: ActivityGraphWindowSchema,
  stats_history: optional(array(ActivityGraphStatsHistoryEntrySchema)),
})

// Swimlane span `kind` / `status` are free-form for the same reason
// as the graph node's status above: operators render them via a
// label/color lookup that falls back to the raw string.
const AgentSpanSchema = object({
  agent: string(),
  start_ms: number(),
  end_ms: number(),
  kind: string(),
  label: string(),
  status: string(),
})

const SwimlaneResponseSchema = object({
  agents: array(string()),
  spans: array(AgentSpanSchema),
  time_range: object({
    min_ms: number(),
    max_ms: number(),
  }),
})

export type ActivityGraphNode = InferOutput<typeof ActivityGraphNodeSchema>
export type ActivityGraphEdge = InferOutput<typeof ActivityGraphEdgeSchema>
export type ActivityGraphTimelineEvent = InferOutput<typeof ActivityGraphTimelineEventSchema>
export type ActivityGraphStats = InferOutput<typeof ActivityGraphStatsSchema>
export type ActivityGraphKindCounts = InferOutput<typeof ActivityGraphKindCountsSchema>
export type ActivityGraphHeatmap = InferOutput<typeof ActivityGraphHeatmapSchema>
export type ActivityGraphResponse = InferOutput<typeof ActivityGraphResponseSchema>
export type AgentSpan = InferOutput<typeof AgentSpanSchema>
export type SwimlaneResponse = InferOutput<typeof SwimlaneResponseSchema>

export class ActionsActivitySchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  readonly endpoint: 'graph' | 'swimlane'
  constructor(endpoint: 'graph' | 'swimlane', issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .slice(0, 3)
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`activity ${endpoint} schema drift: ${summary}`)
    this.name = ActionsActivitySchemaDriftError.name
    this.endpoint = endpoint
    this.issues = issues
  }
}

// abortEarly: both payloads carry unbounded arrays (timeline, spans,
// nodes, edges). A total-drift response would otherwise retain
// thousands of issue objects per error instance.
export function parseActivityGraphResponse(data: unknown): ActivityGraphResponse {
  const result = safeParse(ActivityGraphResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new ActionsActivitySchemaDriftError('graph', result.issues)
  }
  return result.output
}

export function parseSwimlaneResponse(data: unknown): SwimlaneResponse {
  const result = safeParse(SwimlaneResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new ActionsActivitySchemaDriftError('swimlane', result.issues)
  }
  return result.output
}

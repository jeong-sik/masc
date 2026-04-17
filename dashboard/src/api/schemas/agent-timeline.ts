// Agent timeline schema — schema-at-boundary for
// `GET /api/v1/agent-timeline?agent_name=<name>&since_hours=<N>&limit=<K>`.
//
// `event.type` is open `string()` because the backend adds new event
// kinds ahead of the dashboard; consumers dispatch on the string with a
// default case, so a strict picklist would suppress legitimate events.
// `event.detail` is `record(string, unknown)` — opaque structured
// metadata, consumed defensively.

import {
  array,
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

export const AgentTimelineEventSchema = object({
  ts: string(),
  type: string(),
  detail: record(string(), unknown()),
})

const AgentTimelinePeriodSchema = object({
  from: string(),
  to: string(),
})

const AgentTimelineSummarySchema = object({
  tasks_completed: number(),
  tasks_claimed: number(),
  messages_sent: number(),
  tool_calls: optional(number()),
  active_duration_minutes: number(),
  total_events: number(),
})

export const AgentTimelineResponseSchema = object({
  agent: string(),
  period: AgentTimelinePeriodSchema,
  events: array(AgentTimelineEventSchema),
  summary: AgentTimelineSummarySchema,
})

export type AgentTimelineEvent = InferOutput<typeof AgentTimelineEventSchema>
export type AgentTimelineResponse = InferOutput<typeof AgentTimelineResponseSchema>

export class AgentTimelineSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`agent-timeline schema drift: ${summary}`)
    this.name = AgentTimelineSchemaDriftError.name
    this.issues = issues
  }
}

export function parseAgentTimelineResponse(data: unknown): AgentTimelineResponse {
  const result = safeParse(AgentTimelineResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new AgentTimelineSchemaDriftError(result.issues)
  }
  return result.output
}

// Agent relations schema — schema-at-boundary for
// `GET /api/v1/agent-relations?agent_name=<name>`.
//
// `type`, `category`, `role`, `kind` are kept as open `string()` because
// relation taxonomy evolves in the backend (`agent_relations_*.ml`)
// ahead of the dashboard. Strict enums here would brick the agent
// profile page during a backend-ahead deploy window.

import {
  array,
  nullable,
  number,
  object,
  safeParse,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'


export type AgentRelation = InferOutput<typeof AgentRelationSchema>
export type AgentRelationsResponse = InferOutput<typeof AgentRelationsResponseSchema>

export class AgentRelationsSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`agent-relations schema drift: ${summary}`)
    this.name = AgentRelationsSchemaDriftError.name
    this.issues = issues
  }
}

export function parseAgentRelationsResponse(data: unknown): AgentRelationsResponse {
  const result = safeParse(AgentRelationsResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new AgentRelationsSchemaDriftError(result.issues)
  }
  return result.output
}

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

const AgentCollaboratorSchema = object({
  name: string(),
  collaborations: number(),
  last_collab: nullable(string()),
})

const AgentRelationParticipantSchema = object({
  kind: string(),
  display_name: nullable(string()),
  role: nullable(string()),
})

const AgentRelationSchema = object({
  type: string(),
  category: nullable(string()),
  confidence: nullable(number()),
  note: nullable(string()),
  participants: array(AgentRelationParticipantSchema),
})

const AgentRelationsResponseSchema = object({
  agent_name: string(),
  collaborators: array(AgentCollaboratorSchema),
  interests: array(string()),
  relations: array(AgentRelationSchema),
})

export type AgentCollaborator = InferOutput<typeof AgentCollaboratorSchema>
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

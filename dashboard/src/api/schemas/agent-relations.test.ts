import { describe, expect, it } from 'vitest'

import {
  AgentRelationsSchemaDriftError,
  parseAgentRelationsResponse,
} from './agent-relations'

function validResponse(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    agent_name: 'alice',
    collaborators: [
      { name: 'planner', collaborations: 7, last_collab: '2026-04-17T00:00:00Z' },
      { name: 'critic', collaborations: 2, last_collab: null },
    ],
    interests: ['code-review', 'security'],
    relations: [
      {
        type: 'reviews',
        category: 'technical',
        confidence: 0.87,
        note: null,
        participants: [
          { kind: 'agent', display_name: 'alice', role: 'author' },
          { kind: 'agent', display_name: 'critic', role: 'reviewer' },
        ],
      },
    ],
    ...overrides,
  }
}

describe('parseAgentRelationsResponse', () => {
  it('accepts a well-formed response', () => {
    const out = parseAgentRelationsResponse(validResponse())
    expect(out.agent_name).toBe('alice')
    expect(out.collaborators).toHaveLength(2)
    expect(out.relations[0]!.participants).toHaveLength(2)
  })

  it('preserves dashboard feed provenance metadata', () => {
    const out = parseAgentRelationsResponse(
      validResponse({
        dashboard_surface: '/api/v1/agent-relations',
        source: 'second_brain_graphql',
        generated_at_iso: '2026-04-17T04:00:01Z',
        retention: {
          scope: 'external_graphql_query',
          durable_store: 'Second Brain GraphQL',
        },
      }),
    )
    expect(out.dashboard_surface).toBe('/api/v1/agent-relations')
    expect(out.source).toBe('second_brain_graphql')
    expect(out.retention?.durable_store).toBe('Second Brain GraphQL')
    expect(out.generated_at_iso).toBe('2026-04-17T04:00:01Z')
  })

  it('accepts empty collections', () => {
    const out = parseAgentRelationsResponse({
      agent_name: 'new-agent',
      collaborators: [],
      interests: [],
      relations: [],
    })
    expect(out.agent_name).toBe('new-agent')
  })

  it('preserves read-error state for unknown relation sections', () => {
    const out = parseAgentRelationsResponse(
      validResponse({
        collaborators_known: false,
        interests_known: true,
        relations_known: false,
        collaborators: [],
        relations: [],
        read_errors: [
          {
            source: 'agentCollaborationNetworkByName',
            message: 'GraphQL error: unavailable',
          },
          {
            source: 'agent.relations',
            message: 'HTTP 503',
          },
        ],
      }),
    )
    expect(out.collaborators_known).toBe(false)
    expect(out.interests_known).toBe(true)
    expect(out.relations_known).toBe(false)
    expect(out.read_errors).toHaveLength(2)
    expect(out.read_errors?.[0]?.source).toBe('agentCollaborationNetworkByName')
  })

  it('accepts unknown relation type values', () => {
    const out = parseAgentRelationsResponse(
      validResponse({
        relations: [
          {
            type: 'brand-new-relation-kind',
            category: null,
            confidence: null,
            note: null,
            participants: [],
          },
        ],
      }),
    )
    expect(out.relations[0]!.type).toBe('brand-new-relation-kind')
  })

  it('throws when agent_name is missing', () => {
    const bad = validResponse({ agent_name: undefined })
    expect(() => parseAgentRelationsResponse(bad)).toThrow(AgentRelationsSchemaDriftError)
  })

  it('throws when relations has a non-object entry', () => {
    const bad = validResponse({ relations: ['not-an-object'] })
    expect(() => parseAgentRelationsResponse(bad)).toThrow(AgentRelationsSchemaDriftError)
  })

  it('throws when a collaborator is missing the name field', () => {
    const bad = validResponse({
      collaborators: [{ collaborations: 1, last_collab: null }],
    })
    expect(() => parseAgentRelationsResponse(bad)).toThrow(AgentRelationsSchemaDriftError)
  })

  it('throws on non-object payload', () => {
    expect(() => parseAgentRelationsResponse(null)).toThrow(AgentRelationsSchemaDriftError)
    expect(() => parseAgentRelationsResponse('oops')).toThrow(AgentRelationsSchemaDriftError)
  })
})

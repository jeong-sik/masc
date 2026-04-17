import { describe, expect, it } from 'vitest'

import {
  AgentRelationsSchemaDriftError,
  parseAgentRelationsResponse,
} from './agent-relations'

function validResponse(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    agent_name: 'dreamer',
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
          { kind: 'agent', display_name: 'dreamer', role: 'author' },
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
    expect(out.agent_name).toBe('dreamer')
    expect(out.collaborators).toHaveLength(2)
    expect(out.relations[0]!.participants).toHaveLength(2)
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

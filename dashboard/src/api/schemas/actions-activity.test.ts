import { describe, expect, it } from 'vitest'

import {
  ActionsActivitySchemaDriftError,
  parseActivityGraphResponse,
  parseSwimlaneResponse,
} from './actions-activity'

function validGraph(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    nodes: [
      {
        id: 'agent:claude',
        label: 'claude',
        weight: 3,
        kind: 'agent',
        status: 'active',
      },
    ],
    edges: [
      {
        source: 'agent:claude',
        target: 'task:abc',
        kind: 'claimed',
        weight: 1,
        active: true,
      },
    ],
    stats: { event_count: 42, node_count: 7 },
    kind_counts: { task: 3, message: 10 },
    heatmap: {
      matrix: [[0, 1], [2, 0]],
      max: 2,
      total: 3,
    },
    timeline: [
      {
        kind: 'task.done',
        actor: { id: 'claude', kind: 'agent' },
        subject: { id: 'task:abc', kind: 'task' },
        ts_ms: 1_712_000_000,
        ts_iso: '2026-04-01T00:00:00Z',
        seq: 1,
        room_id: 'main',
        tags: ['done'],
        payload: { task_title: 'finished something', note: 'ok' },
      },
    ],
    generated_at: '2026-04-17T00:00:00Z',
    window: { limit: 500, room_id: null, kinds: [] },
    ...overrides,
  }
}

function validSwimlane(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    agents: ['claude', 'codex'],
    spans: [
      {
        agent: 'claude',
        start_ms: 1_712_000_000_000,
        end_ms: 1_712_000_001_000,
        kind: 'turn',
        label: 'prompt',
        status: 'done',
      },
    ],
    time_range: { min_ms: 1_712_000_000_000, max_ms: 1_712_000_001_000 },
    ...overrides,
  }
}

describe('parseActivityGraphResponse', () => {
  it('accepts a minimal valid payload without stats_history', () => {
    const out = parseActivityGraphResponse(validGraph())
    expect(out.nodes).toHaveLength(1)
    expect(out.edges).toHaveLength(1)
    expect(out.stats.event_count).toBe(42)
    expect(out.stats_history).toBeUndefined()
    expect(out.timeline[0]!.actor).toEqual({ id: 'claude', kind: 'agent' })
    expect(out.timeline[0]!.subject).toEqual({ id: 'task:abc', type: 'task' })
    expect(out.timeline[0]!.summary).toBe('finished something')
    expect(out.timeline[0]!.ts).toBe(1_712_000_000)
  })

  it('accepts optional stats_history and node.semantic_weight', () => {
    const out = parseActivityGraphResponse(
      validGraph({
        nodes: [
          {
            id: 'agent:claude',
            label: 'claude',
            weight: 3,
            semantic_weight: 0.42,
            kind: 'agent',
            status: 'active',
            last_event_at: '2026-04-17T00:00:00Z',
            meta: { foo: 'bar' },
          },
        ],
        stats_history: [
          { bucket: 0, events: 10, active_agents: 2, tasks_done: 1 },
          { bucket: 1, events: 5, active_agents: 3, tasks_done: 0 },
        ],
      }),
    )
    expect(out.nodes[0]!.semantic_weight).toBe(0.42)
    expect(out.stats_history).toHaveLength(2)
  })

  it('accepts unknown node.kind and node.status (open enum policy)', () => {
    const out = parseActivityGraphResponse(
      validGraph({
        nodes: [
          {
            id: 'n',
            label: 'novel',
            weight: 1,
            kind: 'novel_kind_from_backend',
            status: 'novel_status',
          },
        ],
      }),
    )
    expect(out.nodes[0]!.kind).toBe('novel_kind_from_backend')
    expect(out.nodes[0]!.status).toBe('novel_status')
  })

  it('throws when a required field is missing', () => {
    const bad = validGraph()
    delete (bad as Record<string, unknown>).generated_at
    expect(() => parseActivityGraphResponse(bad)).toThrow(ActionsActivitySchemaDriftError)
  })

  it('throws when heatmap.matrix contains non-numbers', () => {
    const bad = validGraph({
      heatmap: { matrix: [['not-a-number']], max: 0, total: 0 },
    })
    expect(() => parseActivityGraphResponse(bad)).toThrow(ActionsActivitySchemaDriftError)
  })

  it('normalizes null actor and derives summary from payload', () => {
    const out = parseActivityGraphResponse(
      validGraph({
        timeline: [
          {
            kind: 'tool.called',
            actor: null,
            subject: { id: 'keeper_shell', kind: 'tool' },
            ts_ms: 1_712_100_000,
            ts_iso: '2026-04-01T00:16:40Z',
            seq: 2,
            room_id: 'default',
            tags: ['tool'],
            payload: { tool_name: 'keeper_shell', cmd: 'pr create --draft' },
          },
        ],
      }),
    )
    expect(out.timeline[0]!.actor).toEqual({})
    expect(out.timeline[0]!.subject).toEqual({ id: 'keeper_shell', type: 'tool' })
    expect(out.timeline[0]!.summary).toBe('pr create --draft')
    expect(out.timeline[0]!.ts).toBe(1_712_100_000)
  })

  it('throws on non-object payload', () => {
    expect(() => parseActivityGraphResponse(null)).toThrow(ActionsActivitySchemaDriftError)
    expect(() => parseActivityGraphResponse('string')).toThrow(ActionsActivitySchemaDriftError)
  })

  it('tags thrown errors with the graph endpoint', () => {
    try {
      parseActivityGraphResponse({})
      throw new Error('expected throw')
    } catch (err) {
      expect(err).toBeInstanceOf(ActionsActivitySchemaDriftError)
      expect((err as ActionsActivitySchemaDriftError).endpoint).toBe('graph')
    }
  })
})

describe('parseSwimlaneResponse', () => {
  it('accepts a valid swimlane payload', () => {
    const out = parseSwimlaneResponse(validSwimlane())
    expect(out.agents).toEqual(['claude', 'codex'])
    expect(out.spans).toHaveLength(1)
    expect(out.time_range.min_ms).toBe(1_712_000_000_000)
  })

  it('throws when spans is not an array', () => {
    const bad = validSwimlane({ spans: 'not-an-array' })
    expect(() => parseSwimlaneResponse(bad)).toThrow(ActionsActivitySchemaDriftError)
  })

  it('tags thrown errors with the swimlane endpoint', () => {
    try {
      parseSwimlaneResponse({})
      throw new Error('expected throw')
    } catch (err) {
      expect(err).toBeInstanceOf(ActionsActivitySchemaDriftError)
      expect((err as ActionsActivitySchemaDriftError).endpoint).toBe('swimlane')
    }
  })
})

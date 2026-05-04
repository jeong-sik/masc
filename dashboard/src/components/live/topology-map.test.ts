import { describe, it, expect } from 'vitest'
import {
  topologyNodeColor,
  buildTopologyGraph,
  type TopologyGraph,
} from './topology-map'
import type { Agent, Task, Keeper } from '../../types/core'

// ─── Helpers ─────────────────────────────────────────────────────────────────

function makeAgent(partial: Partial<Agent> = {}): Agent {
  return { name: 'agent-1', current_task: null, ...partial }
}

function makeTask(partial: Partial<Task> = {}): Task {
  return { id: 't-1', title: 'Test task', ...partial }
}

function makeKeeper(partial: Partial<Keeper> = {}): Keeper {
  return { name: 'keeper-1', status: 'active', ...partial }
}

// ─── topologyNodeColor ────────────────────────────────────────────────────────

describe('topologyNodeColor', () => {
  it('returns dim color for offline agent', () => {
    expect(topologyNodeColor('agent', 'offline')).toBe('var(--color-fg-disabled)')
  })

  it('returns dim color for inactive agent', () => {
    expect(topologyNodeColor('agent', 'inactive')).toBe('var(--color-fg-disabled)')
  })

  it('returns cyan for active agent', () => {
    expect(topologyNodeColor('agent', 'active')).toBe('var(--cyan)')
  })

  it('returns cyan for busy agent', () => {
    expect(topologyNodeColor('agent', 'busy')).toBe('var(--cyan)')
  })

  it('returns muted cyan for idle agent', () => {
    expect(topologyNodeColor('agent', 'idle')).toBe('var(--info-border)')
  })

  it('returns green for active keeper', () => {
    expect(topologyNodeColor('keeper', 'active')).toBe('var(--color-status-ok)')
  })

  it('returns warn color for awaiting_verification task', () => {
    expect(topologyNodeColor('task', 'awaiting_verification')).toBe('var(--color-status-warn)')
  })

  it('returns muted green for done task', () => {
    expect(topologyNodeColor('task', 'done')).toBe('var(--ok-border)')
  })

  it('returns yellow for in_progress task', () => {
    expect(topologyNodeColor('task', 'in_progress')).toBe('var(--warn-fg)')
  })
})

// ─── buildTopologyGraph ───────────────────────────────────────────────────────

describe('buildTopologyGraph', () => {
  it('returns empty graph when all inputs are empty', () => {
    const graph = buildTopologyGraph([], [], [])
    expect(graph.nodes).toHaveLength(0)
    expect(graph.edges).toHaveLength(0)
  })

  it('includes keeper nodes', () => {
    const graph = buildTopologyGraph([], [], [makeKeeper({ name: 'k1' })])
    expect(graph.nodes).toHaveLength(1)
    expect(graph.nodes[0]!.id).toBe('keeper:k1')
    expect(graph.nodes[0]!.kind).toBe('keeper')
  })

  it('uses koreanName as label when available', () => {
    const graph = buildTopologyGraph(
      [],
      [],
      [makeKeeper({ name: 'k1', koreanName: '수호자' })],
    )
    expect(graph.nodes[0]!.label).toBe('수호자')
  })

  it('falls back to name when koreanName is empty', () => {
    const graph = buildTopologyGraph(
      [],
      [],
      [makeKeeper({ name: 'k1', koreanName: '' })],
    )
    expect(graph.nodes[0]!.label).toBe('k1')
  })

  it('includes agent nodes', () => {
    const graph = buildTopologyGraph([makeAgent({ name: 'a1', status: 'active' })], [], [])
    const agentNode = graph.nodes.find(n => n.id === 'agent:a1')
    expect(agentNode).toBeDefined()
    expect(agentNode!.kind).toBe('agent')
    expect(agentNode!.status).toBe('active')
  })

  it('creates supervised_by edge when agent has matching keeper_name', () => {
    const graph = buildTopologyGraph(
      [makeAgent({ name: 'a1', keeper_name: 'k1' })],
      [],
      [makeKeeper({ name: 'k1' })],
    )
    const edge = graph.edges.find(e => e.kind === 'supervised_by')
    expect(edge).toBeDefined()
    expect(edge!.from).toBe('agent:a1')
    expect(edge!.to).toBe('keeper:k1')
  })

  it('does not create supervisor edge when keeper is unknown', () => {
    const graph = buildTopologyGraph(
      [makeAgent({ name: 'a1', keeper_name: 'unknown-keeper' })],
      [],
      [],
    )
    expect(graph.edges).toHaveLength(0)
  })

  it('does not create supervisor edge when keeper_name is null', () => {
    const graph = buildTopologyGraph(
      [makeAgent({ name: 'a1', keeper_name: null })],
      [],
      [makeKeeper({ name: 'k1' })],
    )
    expect(graph.edges).toHaveLength(0)
  })

  it('includes in_progress tasks as nodes', () => {
    const graph = buildTopologyGraph([], [makeTask({ id: 't1', status: 'in_progress' })], [])
    expect(graph.nodes.find(n => n.id === 'task:t1')).toBeDefined()
  })

  it('includes claimed tasks as nodes', () => {
    const graph = buildTopologyGraph([], [makeTask({ id: 't1', status: 'claimed' })], [])
    expect(graph.nodes.find(n => n.id === 'task:t1')).toBeDefined()
  })

  it('includes awaiting_verification tasks as nodes', () => {
    const graph = buildTopologyGraph(
      [],
      [makeTask({ id: 't1', status: 'awaiting_verification' })],
      [],
    )
    expect(graph.nodes.find(n => n.id === 'task:t1')).toBeDefined()
  })

  it('excludes done tasks from nodes', () => {
    const graph = buildTopologyGraph([], [makeTask({ id: 't1', status: 'done' })], [])
    expect(graph.nodes.find(n => n.id === 'task:t1')).toBeUndefined()
  })

  it('excludes todo tasks from nodes', () => {
    const graph = buildTopologyGraph([], [makeTask({ id: 't1', status: 'todo' })], [])
    expect(graph.nodes.find(n => n.id === 'task:t1')).toBeUndefined()
  })

  it('creates assigned_to edge from task to its assignee agent', () => {
    const graph = buildTopologyGraph(
      [makeAgent({ name: 'a1', status: 'active' })],
      [makeTask({ id: 't1', status: 'in_progress', assignee: 'a1' })],
      [],
    )
    const edge = graph.edges.find(e => e.kind === 'assigned_to')
    expect(edge).toBeDefined()
    expect(edge!.from).toBe('task:t1')
    expect(edge!.to).toBe('agent:a1')
  })

  it('does not create assigned_to edge when assignee is unknown', () => {
    const graph = buildTopologyGraph(
      [],
      [makeTask({ id: 't1', status: 'in_progress', assignee: 'nonexistent' })],
      [],
    )
    expect(graph.edges).toHaveLength(0)
  })

  it('truncates long task titles', () => {
    const longTitle = 'A'.repeat(30)
    const graph = buildTopologyGraph([], [makeTask({ id: 't1', status: 'in_progress', title: longTitle })], [])
    const node = graph.nodes.find(n => n.id === 'task:t1')
    expect(node).toBeDefined()
    expect(node!.label.length).toBeLessThanOrEqual(24)
    expect(node!.label.endsWith('…')).toBe(true)
  })

  it('does not truncate short task titles', () => {
    const graph = buildTopologyGraph(
      [],
      [makeTask({ id: 't1', status: 'in_progress', title: 'Short title' })],
      [],
    )
    const node = graph.nodes.find(n => n.id === 'task:t1')
    expect(node).toBeDefined()
    expect(node!.label).toBe('Short title')
  })

  it('builds a full graph with agents, tasks, and keepers', () => {
    const graph: TopologyGraph = buildTopologyGraph(
      [makeAgent({ name: 'a1', status: 'active', keeper_name: 'k1' })],
      [makeTask({ id: 't1', status: 'in_progress', assignee: 'a1' })],
      [makeKeeper({ name: 'k1' })],
    )
    expect(graph.nodes).toHaveLength(3) // keeper + agent + task
    expect(graph.edges).toHaveLength(2) // supervised_by + assigned_to
    expect(graph.edges.some(e => e.kind === 'supervised_by')).toBe(true)
    expect(graph.edges.some(e => e.kind === 'assigned_to')).toBe(true)
  })
})

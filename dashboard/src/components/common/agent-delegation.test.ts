import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentDelegation,
  flattenDelegationTree,
  formatElapsed,
  statusToPresence,
  summarizeDelegationTree,
} from './agent-delegation'
import type { DelegationNode } from './agent-delegation'

const now = new Date('2026-05-06T00:00:00Z').getTime()
const rootNode: DelegationNode = {
  agentId: 'agent-alpha-123',
  task: 'root task',
  status: 'active',
  startedAt: now,
  completedAt: now + 5000,
  children: [
    {
      agentId: 'agent-beta-456',
      task: 'child task',
      status: 'completed',
      startedAt: now + 1000,
      completedAt: now + 4000,
    },
    {
      agentId: 'agent-gamma-789',
      task: 'failed child task',
      status: 'failed',
    },
  ],
}

describe('delegation helpers', () => {
  it('maps node status to presence state', () => {
    expect(statusToPresence('active')).toBe('busy')
    expect(statusToPresence('completed')).toBe('active')
    expect(statusToPresence('failed')).toBe('inactive')
    expect(statusToPresence('pending')).toBe('idle')
  })

  it('formats elapsed time only for valid timestamps', () => {
    expect(formatElapsed(now, now + 2500)).toBe('2.5s')
    expect(formatElapsed(now + 2500, now)).toBeNull()
    expect(formatElapsed(now, undefined)).toBeNull()
  })

  it('flattens delegation tree with depth and leaf metadata', () => {
    const flat = flattenDelegationTree(rootNode)
    expect(flat.map((item) => [item.node.agentId, item.depth, item.leaf])).toEqual([
      ['agent-alpha-123', 0, false],
      ['agent-beta-456', 1, true],
      ['agent-gamma-789', 1, true],
    ])
    expect(flat[0]?.childCount).toBe(2)
  })

  it('summarizes delegation tree counts and status', () => {
    const summary = summarizeDelegationTree(rootNode)
    expect(summary.totalCount).toBe(3)
    expect(summary.leafCount).toBe(2)
    expect(summary.maxDepth).toBe(1)
    expect(summary.activeCount).toBe(1)
    expect(summary.completedCount).toBe(1)
    expect(summary.failedCount).toBe(1)
    expect(summary.latestStartedAt).toBe(now + 1000)
    expect(summary.latestCompletedAt).toBe(now + 5000)
    expect(summary.longestElapsedMs).toBe(5000)
    expect(summary.status).toBe('failed')
  })
})

describe('AgentDelegation', () => {
  it('renders tree role', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.querySelector('[role="tree"]')).not.toBeNull()
  })

  it('renders root task', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.textContent).toContain('root task')
  })

  it('renders agent id short', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.textContent).toContain('agent-al')
  })

  it('renders elapsed time', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.textContent).toContain('5.0s')
  })

  it('renders child node', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.textContent).toContain('child task')
  })

  it('renders child elapsed', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.textContent).toContain('3.0s')
  })

  it('does not render elapsed when missing timestamps', () => {
    const container = document.createElement('div')
    const node = { agentId: 'a1', task: 't', status: 'pending' as const }
    render(h(AgentDelegation, { root: node }), container)
    expect(container.textContent).not.toContain('s)')
  })

  it('renders treeitem roles', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.querySelectorAll('[role="treeitem"]').length).toBe(3)
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode, testId: 'ad-1' }), container)
    expect(container.querySelector('[data-testid="ad-1"]')).not.toBeNull()
  })

  it('renders data-agent-delegation', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    expect(container.querySelector('[data-agent-delegation]')).not.toBeNull()
  })

  it('exposes root summary data attributes', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    const root = container.querySelector('[data-agent-delegation]') as HTMLElement
    expect(root.dataset.agentDelegationTotalCount).toBe('3')
    expect(root.dataset.agentDelegationLeafCount).toBe('2')
    expect(root.dataset.agentDelegationMaxDepth).toBe('1')
    expect(root.dataset.agentDelegationActiveCount).toBe('1')
    expect(root.dataset.agentDelegationCompletedCount).toBe('1')
    expect(root.dataset.agentDelegationFailedCount).toBe('1')
    expect(root.dataset.agentDelegationLatestStartedAt).toBe(String(now + 1000))
    expect(root.dataset.agentDelegationLatestCompletedAt).toBe(String(now + 5000))
    expect(root.dataset.agentDelegationLongestElapsedMs).toBe('5000')
    expect(root.dataset.agentDelegationStatus).toBe('failed')
  })

  it('exposes node data attributes', () => {
    const container = document.createElement('div')
    render(h(AgentDelegation, { root: rootNode }), container)
    const child = container.querySelector('[data-delegation-agent-id="agent-beta-456"]') as HTMLElement
    expect(child.dataset.delegationTask).toBe('child task')
    expect(child.dataset.delegationStatus).toBe('completed')
    expect(child.dataset.delegationDepth).toBe('1')
    expect(child.dataset.delegationPath).toBe('0.0')
    expect(child.dataset.delegationChildCount).toBe('0')
    expect(child.dataset.delegationLeaf).toBe('true')
    expect(child.dataset.delegationElapsedMs).toBe('3000')
  })
})

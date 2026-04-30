import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentDelegation } from './agent-delegation'

const rootNode = {
  agentId: 'agent-alpha-123',
  task: 'root task',
  status: 'active' as const,
  startedAt: Date.now(),
  completedAt: Date.now() + 5000,
  children: [
    {
      agentId: 'agent-beta-456',
      task: 'child task',
      status: 'completed' as const,
      startedAt: Date.now(),
      completedAt: Date.now() + 3000,
    },
  ],
}

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
    expect(container.querySelectorAll('[role="treeitem"]').length).toBe(2)
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
})

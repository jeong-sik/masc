// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentDelegation } from './agent-delegation'

describe('AgentDelegation a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const rootNode = {
    agentId: 'agent-root-001',
    task: 'Deploy to production',
    status: 'active' as const,
    startedAt: Date.now() - 5000,
    children: [
      {
        agentId: 'agent-child-002',
        task: 'Run migration scripts',
        status: 'completed' as const,
        startedAt: Date.now() - 4000,
        completedAt: Date.now() - 1000,
      },
      {
        agentId: 'agent-child-003',
        task: 'Verify health checks',
        status: 'pending' as const,
        children: [
          {
            agentId: 'agent-grand-004',
            task: 'Check /ready endpoint',
            status: 'failed' as const,
          },
        ],
      },
    ],
  }

  it('renders accessibly', async () => {
    render(html`<${AgentDelegation} root=${rootNode} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=tree', () => {
    render(html`<${AgentDelegation} root=${rootNode} />`, container)
    const tree = container.querySelector('[role="tree"]')
    expect(tree).not.toBeNull()
  })

  it('renders treeitem roles for all nodes', () => {
    render(html`<${AgentDelegation} root=${rootNode} />`, container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBe(4)
  })

  it('renders nested children', () => {
    render(html`<${AgentDelegation} root=${rootNode} />`, container)
    expect(container.textContent).toContain('Deploy to production')
    expect(container.textContent).toContain('Run migration scripts')
    expect(container.textContent).toContain('Verify health checks')
    expect(container.textContent).toContain('Check /ready endpoint')
  })

  it('shows elapsed time for completed nodes', () => {
    render(html`<${AgentDelegation} root=${rootNode} />`, container)
    expect(container.textContent).toContain('s)')
  })

  it('renders flat root without children', async () => {
    const flat = {
      agentId: 'agent-flat-999',
      task: 'Standalone task',
      status: 'completed' as const,
      startedAt: Date.now() - 2000,
      completedAt: Date.now(),
    }
    render(html`<${AgentDelegation} root=${flat} />`, container)
    expect(container.querySelectorAll('[role="treeitem"]').length).toBe(1)
    expect(await axe(container)).toHaveNoViolations()
  })
})

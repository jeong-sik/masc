// @vitest-environment happy-dom
//
// jest-axe coverage for CytoscapeFsm wrapper. Cytoscape is lazy-
// loaded and renders into the host div imperatively — happy-dom
// can't resolve the dynamic import but the wrapper + loading state
// must axe-clean across spec variations.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CytoscapeFsm } from './cytoscape-fsm'
import type { FsmGraphSpec } from './cytoscape-fsm'

const trivialSpec: FsmGraphSpec = {
  nodes: [
    { id: 'idle', label: 'idle', type: 'state' },
    { id: 'busy', label: 'busy', type: 'active' },
  ],
  edges: [
    { source: 'idle', target: 'busy', label: 'start' },
    { source: 'busy', target: 'idle', label: 'done', type: 'recovery' },
  ],
}

describe('CytoscapeFsm a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render with simple FSM passes axe', async () => {
    render(html`<${CytoscapeFsm} spec=${trivialSpec} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with active node + custom height passes axe', async () => {
    const withActive: FsmGraphSpec = {
      ...trivialSpec,
      activeNodeId: 'busy',
    }
    render(
      html`<${CytoscapeFsm} spec=${withActive} height="400px" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with cascade + error edge types passes axe', async () => {
    const withTypes: FsmGraphSpec = {
      nodes: [
        { id: 'a', label: 'a', type: 'start' },
        { id: 'b', label: 'b', type: 'state' },
        { id: 'c', label: 'c', type: 'end' },
      ],
      edges: [
        { source: 'a', target: 'b', type: 'cascade' },
        { source: 'b', target: 'c', type: 'error' },
      ],
    }
    render(html`<${CytoscapeFsm} spec=${withTypes} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

// @vitest-environment happy-dom
//
// jest-axe coverage for MermaidGraph wrapper. The actual graph is
// rendered async by the lazy-loaded mermaid library; happy-dom won't
// resolve it but the wrapper element + fallback text path should
// still axe-clean.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MermaidGraph } from './mermaid-graph'

describe('MermaidGraph a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('wrapper renders accessibly while mermaid lazy-loads', async () => {
    const source = 'graph LR;\n  A-->B;\n  B-->C;'
    render(html`<${MermaidGraph} source=${source} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with fallbackText passes axe', async () => {
    render(
      html`<${MermaidGraph}
        source="graph TD; X-->Y;"
        fallbackText="Diagram unavailable — see source above."
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with custom min-height + diagramClass passes axe', async () => {
    render(
      html`<${MermaidGraph}
        source="graph LR; alpha-->beta;"
        minHeightClass="min-h-60"
        diagramClass="border border-[var(--white-5)]"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

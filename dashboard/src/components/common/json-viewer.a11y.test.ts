// @vitest-environment happy-dom
//
// jest-axe coverage for JsonViewer / JsonViewerCard. Tree-style
// data display. axe primarily guards: (1) the recursive nested
// `<details>` / `<summary>` structure (when collapsible) keeps a
// proper accessibility tree, and (2) the colored type-tagged spans
// (string/number/boolean) maintain WCAG AA contrast.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { fireEvent } from '@testing-library/preact'
import { JsonViewer, JsonViewerCard } from './json-viewer'

describe('JsonViewer a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('flat object passes axe', async () => {
    render(
      html`<${JsonViewer} data=${{ name: 'masc', version: 1 }} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('nested object + array passes axe', async () => {
    render(
      html`<${JsonViewer}
        data=${{
          agents: ['a', 'b'],
          status: { ok: true, count: 12 },
        }}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with label passes axe', async () => {
    render(
      html`<${JsonViewer} data=${[1, 2, 3]} label="numbers" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('initialCollapsed=true passes axe', async () => {
    render(
      html`<${JsonViewer}
        data=${{ a: 1, b: 2 }}
        initialCollapsed=${true}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('null + boolean + string mix passes axe (type-tag color sweep)', async () => {
    render(
      html`<${JsonViewer}
        data=${{ s: 'text', n: 42, b: true, nil: null, arr: [] }}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('JsonViewerCard a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with title passes axe', async () => {
    render(
      html`<${JsonViewerCard}
        title="Run summary"
        data=${{ ok: 12, err: 0 }}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

// Render guards: a single huge string leaf (the 160M-char curator
// raw_response incident) or a very wide container must not flood the DOM on
// first draw. The guards cap what is RENDERED, never what is held in data.
describe('JsonViewer render guards', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('previews a huge string leaf with an expand control instead of flooding the DOM', () => {
    const huge = 'x'.repeat(50_000)
    render(html`<${JsonViewer} data=${{ raw_response: huge }} />`, container)
    const text = container.textContent ?? ''
    expect(text).not.toContain(huge)
    const expand = container.querySelector('button[aria-label^="Expand "]')
    expect(expand).not.toBeNull()
    expect(expand!.textContent).toContain('50,000')
  })

  it('expands a huge string leaf only on explicit request', () => {
    const huge = 'y'.repeat(20_000)
    render(html`<${JsonViewer} data=${{ body: huge }} />`, container)
    expect(container.textContent).not.toContain(huge)
    fireEvent.click(container.querySelector('button[aria-label^="Expand "]')!)
    expect(container.textContent).toContain(huge)
  })

  it('caps rendered items of a wide array and names the unrendered rest', () => {
    const wide = Array.from({ length: 1_000 }, (_, i) => `item-${i}`)
    render(html`<${JsonViewer} data=${wide} />`, container)
    expect(container.textContent).toContain('item-0')
    expect(container.textContent).toContain('item-199')
    expect(container.textContent).not.toContain('item-200')
    expect(container.textContent).toContain('800')
  })

  it('caps rendered entries of a wide object and names the unrendered rest', () => {
    const wide: Record<string, string> = {}
    for (let i = 0; i < 500; i++) wide[`k${i}`] = `v${i}`
    render(html`<${JsonViewer} data=${wide} />`, container)
    const text = container.textContent ?? ''
    expect(text).toContain('k0')
    expect(text).toContain('k199')
    expect(text).not.toContain('k200:')
    expect(text).toContain('300')
  })

  it('lets the user page forward to reach array items past the first batch', () => {
    const wide = Array.from({ length: 1_000 }, (_, i) => `item-${i}`)
    render(html`<${JsonViewer} data=${wide} />`, container)
    expect(container.textContent).not.toContain('item-200')
    fireEvent.click(container.querySelector('button[aria-label^="Show "]')!)
    expect(container.textContent).toContain('item-200')
    expect(container.textContent).toContain('item-399')
    expect(container.textContent).not.toContain('item-400')
  })

  it('lets the user page forward to reach object entries past the first batch', () => {
    const wide: Record<string, string> = {}
    for (let i = 0; i < 500; i++) wide[`k${i}`] = `v${i}`
    render(html`<${JsonViewer} data=${wide} />`, container)
    expect(container.textContent).not.toContain('k200:')
    fireEvent.click(container.querySelector('button[aria-label^="Show "]')!)
    expect(container.textContent).toContain('k200:')
    expect(container.textContent).toContain('k399:')
    expect(container.textContent).not.toContain('k400:')
  })
})

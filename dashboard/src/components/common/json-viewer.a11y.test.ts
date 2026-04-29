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

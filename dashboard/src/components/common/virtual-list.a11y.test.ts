// @vitest-environment happy-dom
//
// jest-axe coverage for VirtualList. Two render paths: below-threshold
// (≤40 items, no virtualization, plain pass-through) and
// above-threshold (windowed render with translateY offset). Both
// must axe-clean — virtualized rendering must not break list semantics
// for AT (rows still discoverable in the DOM, even if windowed).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { VirtualList } from './virtual-list'

const renderItem = (item: string, _i: number) => html`
  <div role="listitem">${item}</div>
`

describe('VirtualList a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('below-threshold (10 items, no virtualization) passes axe', async () => {
    const items = Array.from({ length: 10 }, (_, i) => `item-${i}`)
    render(
      html`<div role="list">
        <${VirtualList}
          items=${items}
          itemHeight=${24}
          renderItem=${renderItem}
          getKey=${(x: string) => x}
        />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('at activation threshold (40 items) passes axe', async () => {
    const items = Array.from({ length: 40 }, (_, i) => `row-${i}`)
    render(
      html`<div role="list">
        <${VirtualList}
          items=${items}
          itemHeight=${20}
          renderItem=${renderItem}
          getKey=${(x: string) => x}
        />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('above-threshold (200 items, virtualized) passes axe', async () => {
    const items = Array.from({ length: 200 }, (_, i) => `entry-${i}`)
    render(
      html`<div role="list">
        <${VirtualList}
          items=${items}
          itemHeight=${24}
          overscan=${3}
          renderItem=${renderItem}
          getKey=${(x: string) => x}
        />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('empty list (0 items) passes axe', async () => {
    render(
      html`<div role="list">
        <${VirtualList}
          items=${[]}
          itemHeight=${24}
          renderItem=${renderItem}
          getKey=${(x: string) => x}
        />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

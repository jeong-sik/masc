// @vitest-environment happy-dom
//
// jest-axe coverage for SurfaceCard / SectionCard. Pure
// container atoms — axe primarily guards landmark-vs-non-landmark
// usage and that the title-bearing variants surface a real heading
// rather than a styled <span>.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { SurfaceCard, SectionCard } from './card'

describe('SurfaceCard a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('standard variant renders accessibly', async () => {
    render(html`<${SurfaceCard}><p>card content</p><//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('light variant renders accessibly', async () => {
    render(html`<${SurfaceCard} variant="light"><p>light</p><//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('compact variant renders accessibly', async () => {
    render(html`<${SurfaceCard} variant="compact"><p>compact</p><//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('SectionCard a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with label renders accessibly', async () => {
    render(
      html`<${SectionCard} label="Recent activity"><p>...</p><//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

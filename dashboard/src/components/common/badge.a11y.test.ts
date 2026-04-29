// @vitest-environment happy-dom
//
// jest-axe coverage for CountBadge — display-only atom with no
// interaction surface. The exhaustive tone sweep guards against a
// future tone palette change accidentally introducing low-contrast
// or color-only-information violations.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CountBadge } from './badge'

describe('CountBadge a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default tone renders accessibly', async () => {
    render(html`<${CountBadge}>12<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('warn tone renders accessibly', async () => {
    render(html`<${CountBadge} tone="warn">3<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('ok tone renders accessibly', async () => {
    render(html`<${CountBadge} tone="ok">8<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('bad tone renders accessibly', async () => {
    render(html`<${CountBadge} tone="bad">5<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('accent tone renders accessibly', async () => {
    render(html`<${CountBadge} tone="accent">21<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { DashedNotice } from './dashed-notice'

describe('DashedNotice a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default sm/card variant renders accessibly', async () => {
    render(html`<${DashedNotice}>No events yet<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('md/subtle variant renders accessibly', async () => {
    render(
      html`<${DashedNotice} size="md" borderTone="subtle">No deployments in this window<//>`,
      container,
    )
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })
})

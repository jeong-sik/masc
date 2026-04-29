// @vitest-environment happy-dom
//
// jest-axe coverage for RouteLink. Anchor element with hash href +
// modifier-key passthrough (cmd+click opens in new tab). Tests pin
// that aria-current=page and the focus ring don't introduce axe
// violations across the navigation tab variants.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { RouteLink } from './route-link'

describe('RouteLink a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default link passes axe', async () => {
    render(
      html`<${RouteLink} tab="overview">Overview</${RouteLink}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('aria-current=page passes axe', async () => {
    render(
      html`<${RouteLink} tab="monitoring" ariaCurrent="page">Monitoring</${RouteLink}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with title attribute passes axe', async () => {
    render(
      html`<${RouteLink}
        tab="logs"
        title="Open the system logs view"
      >Logs</${RouteLink}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('link with params passes axe', async () => {
    render(
      html`<${RouteLink}
        tab="command"
        params=${{ keeper: 'sigma' }}
      >Command sigma</${RouteLink}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

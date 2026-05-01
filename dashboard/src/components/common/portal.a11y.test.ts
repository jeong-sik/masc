// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Portal } from './portal'

async function tick() {
  return new Promise((r) => setTimeout(r, 10))
}

describe('Portal a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(async () => {
    render(null, container)
    await tick()
    document.body.removeChild(container)
  })

  it('renders children in a body-mounted portal', async () => {
    render(
      html`<${Portal}><div data-portal-content>Portal content</div></${Portal}>`,
      container,
    )
    await tick()
    const portalEl = document.querySelector('[data-masc-portal]')
    expect(portalEl).not.toBeNull()
    expect(portalEl?.querySelector('[data-portal-content]')).not.toBeNull()
  })

  it('cleans up portal container on unmount', async () => {
    render(
      html`<${Portal}><div data-portal-content>Portal content</div></${Portal}>`,
      container,
    )
    await tick()
    render(null, container)
    await tick()
    expect(document.querySelector('[data-masc-portal]')).toBeNull()
  })

  it('renders accessibly', async () => {
    render(
      html`<${Portal}><button>Action</button></${Portal}>`,
      container,
    )
    await tick()
    expect(await axe(document.body)).toHaveNoViolations()
  })
})

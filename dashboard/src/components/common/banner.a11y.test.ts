// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Banner } from './banner'

describe('Banner a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(html`<${Banner} aria-label="Site header">Content<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has banner role', () => {
    render(html`<${Banner}>Content<//>`, container)
    expect(container.querySelector('[role="banner"]')).not.toBeNull()
  })

  it('passes aria-label', () => {
    render(html`<${Banner} aria-label="App header">Content<//>`, container)
    const banner = container.querySelector('[role="banner"]')
    expect(banner?.getAttribute('aria-label')).toBe('App header')
  })

  it('renders children', () => {
    render(html`<${Banner}><span>Child<//><//>`, container)
    expect(container.textContent).toContain('Child')
  })
})

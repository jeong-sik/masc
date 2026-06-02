// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Log } from './log'

describe('Log a11y', () => {
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
    render(html`<${Log} aria-label="Events">Message<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role="log"', () => {
    render(html`<${Log}>Message<//>`, container)
    expect(container.querySelector('[role="log"]')).not.toBeNull()
  })

  it('passes aria-label', () => {
    render(html`<${Log} aria-label="Events">Message<//>`, container)
    const log = container.querySelector('[role="log"]')
    expect(log?.getAttribute('aria-label')).toBe('Events')
  })
})

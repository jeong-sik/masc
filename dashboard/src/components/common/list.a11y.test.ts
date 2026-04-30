// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { List, ListItem } from './list'

describe('List a11y', () => {
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
    render(
      html`
        <${List}>
          <${ListItem}>A<//>
          <${ListItem}>B<//>
        <//>
      `,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role="list"', () => {
    render(
      html`
        <${List}>
          <${ListItem}>A<//>
        <//>
      `,
      container,
    )
    expect(container.querySelector('[role="list"]')).not.toBeNull()
  })

  it('items have role="listitem"', () => {
    render(
      html`
        <${List}>
          <${ListItem}>A<//>
          <${ListItem}>B<//>
        <//>
      `,
      container,
    )
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items.length).toBe(2)
    expect(items[0]?.textContent?.trim()).toBe('A')
  })
})

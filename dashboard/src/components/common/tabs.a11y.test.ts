// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Tabs, TabList, Tab, TabPanel } from './tabs'

describe('Tabs a11y', () => {
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
      html`<${Tabs} defaultValue="a">
        <${TabList}>
          <${Tab} value="a">Tab A<//>
          <${Tab} value="b">Tab B<//>
        <//>
        <${TabPanel} value="a">Panel A<//>
        <${TabPanel} value="b">Panel B<//>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('tablist contains tabs with roles', () => {
    render(
      html`<${Tabs} defaultValue="a">
        <${TabList}>
          <${Tab} value="a">A<//>
          <${Tab} value="b">B<//>
        <//>
        <${TabPanel} value="a">PA<//>
      <//>`,
      container,
    )
    const tablist = container.querySelector('[role="tablist"]')
    expect(tablist).not.toBeNull()
    const tabs = container.querySelectorAll('[role="tab"]')
    expect(tabs.length).toBe(2)
  })

  it('active tab has aria-selected true and inactive false', () => {
    render(
      html`<${Tabs} defaultValue="a">
        <${TabList}>
          <${Tab} value="a">A<//>
          <${Tab} value="b">B<//>
        <//>
        <${TabPanel} value="a">PA<//>
        <${TabPanel} value="b">PB<//>
      <//>`,
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    expect(tabs[0]!.getAttribute('aria-selected')).toBe('true')
    expect(tabs[1]!.getAttribute('aria-selected')).toBe('false')
  })

  it('tab controls panel via aria-controls', () => {
    render(
      html`<${Tabs} defaultValue="a">
        <${TabList}>
          <${Tab} value="a">A<//>
        <//>
        <${TabPanel} value="a">PA<//>
      <//>`,
      container,
    )
    const tab = container.querySelector('[role="tab"]') as HTMLElement
    const panel = container.querySelector('[role="tabpanel"]') as HTMLElement
    expect(tab.getAttribute('aria-controls')).toBe(panel.id)
    expect(panel.getAttribute('aria-labelledby')).toBe(tab.id)
  })

  it('switches tab on click', async () => {
    render(
      html`<${Tabs} defaultValue="a">
        <${TabList}>
          <${Tab} value="a">A<//>
          <${Tab} value="b">B<//>
        <//>
        <${TabPanel} value="a">PA<//>
        <${TabPanel} value="b">PB<//>
      <//>`,
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    ;(tabs[1]! as HTMLButtonElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(tabs[0]!.getAttribute('aria-selected')).toBe('false')
    expect(tabs[1]!.getAttribute('aria-selected')).toBe('true')
  })

  it(' ArrowRight cycles tabs and moves focus', async () => {
    render(
      html`<${Tabs} defaultValue="a">
        <${TabList}>
          <${Tab} value="a">A<//>
          <${Tab} value="b">B<//>
        <//>
        <${TabPanel} value="a">PA<//>
      <//>`,
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    ;(tabs[0]! as HTMLButtonElement).focus()
    tabs[0]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(document.activeElement).toBe(tabs[1])
    expect(tabs[1]!.getAttribute('aria-selected')).toBe('true')
  })
})

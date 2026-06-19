// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { PRIMARY_DASHBOARD_NAV_ITEMS } from '../config/navigation'
import { DashboardSurfaceTabs, dashboardSurfaceTabId } from './dashboard-surface-tabs'

const navigate = vi.fn()
const hashForRoute = vi.fn((tab: string, params?: Record<string, string>) => {
  return params ? `#${tab}?${new URLSearchParams(params)}` : `#${tab}`
})

vi.mock('../router', () => ({
  navigate: (...args: Parameters<typeof navigate>) => navigate(...args),
  hashForRoute: (...args: Parameters<typeof hashForRoute>) => hashForRoute(...args),
}))

describe('DashboardSurfaceTabs', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    navigate.mockClear()
    hashForRoute.mockClear()
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders top-level surfaces as an ARIA tablist', () => {
    render(
      html`<${DashboardSurfaceTabs} items=${PRIMARY_DASHBOARD_NAV_ITEMS} currentTab="code" />`,
      container,
    )

    const tablist = container.querySelector('[role="tablist"]')
    expect(tablist?.getAttribute('aria-label')).toBe('Dashboard surfaces')

    const tabs = Array.from(container.querySelectorAll('[role="tab"]'))
    expect(tabs.map(tab => tab.textContent?.trim())).toEqual([
      'Overview',
      'Work',
      'Keepers',
      'Board',
      'IDE',
      'Connectors',
      'Settings',
    ])
    expect(tabs.map(tab => tab.textContent?.trim())).not.toContain('MASC Cockpit')
    expect(tabs).toHaveLength(PRIMARY_DASHBOARD_NAV_ITEMS.length)
  })

  it('marks the current surface as the selected tab', () => {
    render(
      html`<${DashboardSurfaceTabs} items=${PRIMARY_DASHBOARD_NAV_ITEMS} currentTab="code" />`,
      container,
    )

    const codeTab = container.querySelector(`#${dashboardSurfaceTabId('code')}`)
    const overviewTab = container.querySelector(`#${dashboardSurfaceTabId('overview')}`)
    expect(codeTab?.getAttribute('aria-selected')).toBe('true')
    expect(codeTab?.getAttribute('aria-current')).toBe('page')
    expect(codeTab?.getAttribute('tabindex')).toBe('0')
    expect(overviewTab?.getAttribute('aria-selected')).toBe('false')
    expect(overviewTab?.getAttribute('tabindex')).toBe('-1')
  })

  it('moves focus and activates the next surface on ArrowRight', () => {
    render(
      html`<${DashboardSurfaceTabs} items=${PRIMARY_DASHBOARD_NAV_ITEMS} currentTab="overview" />`,
      container,
    )

    const overviewTab = container.querySelector(`#${dashboardSurfaceTabId('overview')}`) as HTMLElement
    const workTab = container.querySelector(`#${dashboardSurfaceTabId('workspace')}`) as HTMLElement
    overviewTab.focus()
    overviewTab.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))

    expect(document.activeElement).toBe(workTab)
    expect(navigate).toHaveBeenCalledWith('workspace', { section: 'work' })
  })

  it('jumps to the last surface on End', () => {
    render(
      html`<${DashboardSurfaceTabs} items=${PRIMARY_DASHBOARD_NAV_ITEMS} currentTab="overview" />`,
      container,
    )

    const overviewTab = container.querySelector(`#${dashboardSurfaceTabId('overview')}`) as HTMLElement
    const settingsTab = container.querySelector(`#${dashboardSurfaceTabId('settings')}`) as HTMLElement
    overviewTab.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }))

    expect(document.activeElement).toBe(settingsTab)
    expect(navigate).toHaveBeenCalledWith('settings', undefined)
  })

  it('passes axe with route tabs and the controlled main panel target', async () => {
    render(
      html`
        <${DashboardSurfaceTabs} items=${PRIMARY_DASHBOARD_NAV_ITEMS} currentTab="overview" />
        <main id="main-content">Overview content</main>
      `,
      container,
    )

    expect(await axe(container)).toHaveNoViolations()
  })

  it('keeps the tablist keyboard-reachable when current surface is hidden', () => {
    // Regression for #15120: primary dashboard navigation hides the cockpit
    // surface, so when currentTab="cockpit" no item matches and the
    // previous active-only tabIndex branch left every tab at tabIndex=-1.
    // The roving-tabindex contract requires exactly one tabIndex=0; fall
    // back to the first visible item so Tab navigation can still reach
    // the tablist. aria-selected stays "false" — we must not lie about
    // selection when nothing in [items] is actually current.
    render(
      html`<${DashboardSurfaceTabs} items=${PRIMARY_DASHBOARD_NAV_ITEMS} currentTab="cockpit" />`,
      container,
    )

    const tabs = Array.from(container.querySelectorAll<HTMLElement>('[role="tab"]'))
    expect(tabs.length).toBeGreaterThan(0)

    const tabbable = tabs.filter(tab => tab.tabIndex === 0)
    expect(tabbable).toHaveLength(1)
    expect(tabbable[0]).toBe(tabs[0])

    for (const tab of tabs) {
      expect(tab.getAttribute('aria-selected')).toBe('false')
      expect(tab.hasAttribute('aria-current')).toBe(false)
    }
  })
})

// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { DASHBOARD_NAV_ITEMS } from '../config/navigation'
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
      html`<${DashboardSurfaceTabs} items=${DASHBOARD_NAV_ITEMS} currentTab="code" />`,
      container,
    )

    const tablist = container.querySelector('[role="tablist"]')
    expect(tablist?.getAttribute('aria-label')).toBe('Dashboard surfaces')

    const tabs = Array.from(container.querySelectorAll('[role="tab"]'))
    expect(tabs.map(tab => tab.textContent?.trim())).toContain('Code')
    expect(tabs).toHaveLength(DASHBOARD_NAV_ITEMS.length)
  })

  it('marks the current surface as the selected tab', () => {
    render(
      html`<${DashboardSurfaceTabs} items=${DASHBOARD_NAV_ITEMS} currentTab="code" />`,
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
      html`<${DashboardSurfaceTabs} items=${DASHBOARD_NAV_ITEMS} currentTab="overview" />`,
      container,
    )

    const overviewTab = container.querySelector(`#${dashboardSurfaceTabId('overview')}`) as HTMLElement
    const monitorTab = container.querySelector(`#${dashboardSurfaceTabId('monitoring')}`) as HTMLElement
    overviewTab.focus()
    overviewTab.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))

    expect(document.activeElement).toBe(monitorTab)
    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'journey' })
  })

  it('jumps to the last surface on End', () => {
    render(
      html`<${DashboardSurfaceTabs} items=${DASHBOARD_NAV_ITEMS} currentTab="overview" />`,
      container,
    )

    const overviewTab = container.querySelector(`#${dashboardSurfaceTabId('overview')}`) as HTMLElement
    const logsTab = container.querySelector(`#${dashboardSurfaceTabId('logs')}`) as HTMLElement
    overviewTab.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }))

    expect(document.activeElement).toBe(logsTab)
    expect(navigate).toHaveBeenCalledWith('logs', undefined)
  })

  it('passes axe with route tabs and the controlled main panel target', async () => {
    render(
      html`
        <${DashboardSurfaceTabs} items=${DASHBOARD_NAV_ITEMS} currentTab="overview" />
        <main id="main-content">Overview content</main>
      `,
      container,
    )

    expect(await axe(container)).toHaveNoViolations()
  })
})

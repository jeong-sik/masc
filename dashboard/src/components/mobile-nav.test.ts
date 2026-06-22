// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { DashboardNavRail } from './mobile-nav'
import type { RouteState } from '../types'

const routerMock = vi.hoisted(() => ({
  navigate: vi.fn(),
  hashForRoute: vi.fn((tab: string, params?: Record<string, string>) => {
    return params ? `#${tab}?${new URLSearchParams(params)}` : `#${tab}`
  }),
  routeState: {
    value: { tab: 'monitoring', params: { section: 'agents' }, postId: null } as RouteState,
  } as { value: RouteState },
}))

vi.mock('../router', () => ({
  route: routerMock.routeState,
  navigate: (...args: Parameters<typeof routerMock.navigate>) => routerMock.navigate(...args),
  hashForRoute: (...args: Parameters<typeof routerMock.hashForRoute>) => routerMock.hashForRoute(...args),
}))

const PRIMARY_LABELS = ['Overview', 'Work', 'Keepers', 'Board'] as const

describe('DashboardNavRail', () => {
  let container: HTMLElement
  let onToggleCollapsed: ReturnType<typeof vi.fn>
  let onToggleDrawer: ReturnType<typeof vi.fn>
  let onCloseDrawer: ReturnType<typeof vi.fn>

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    routerMock.routeState.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null } as RouteState
    routerMock.navigate.mockClear()
    routerMock.hashForRoute.mockClear()
    onToggleCollapsed = vi.fn()
    onToggleDrawer = vi.fn()
    onCloseDrawer = vi.fn()
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function renderNav(props: Partial<Parameters<typeof DashboardNavRail>[0]> = {}) {
    render(html`
      <${DashboardNavRail}
        currentTab=${props.currentTab ?? 'monitoring'}
        mobile=${props.mobile ?? true}
        drawerOpen=${props.drawerOpen ?? false}
        hideMobileTabs=${props.hideMobileTabs ?? false}
        collapsed=${props.collapsed ?? false}
        onToggleCollapsed=${props.onToggleCollapsed ?? onToggleCollapsed}
        onToggleDrawer=${props.onToggleDrawer ?? onToggleDrawer}
        onCloseDrawer=${props.onCloseDrawer ?? onCloseDrawer}
      />
    `, container)
  }

  it('renders one shared rail owner with mobile tabs when the drawer is closed', () => {
    renderNav({ currentTab: 'monitoring', mobile: true, drawerOpen: false })

    expect(container.querySelector('[data-testid="dashboard-nav-rail"]')).not.toBeNull()
    const tabs = container.querySelector('nav[aria-label="Primary mobile navigation"]')
    expect(tabs).not.toBeNull()
    expect(tabs?.className).toContain('v2-mobile-bottom-bar')

    const labels = Array.from(tabs?.querySelectorAll('a, button') ?? [])
      .map(el => el.textContent?.trim())
    expect(labels).toEqual([...PRIMARY_LABELS, 'More'])
  })

  it('marks only the current mobile tab with aria-current=page', () => {
    renderNav({ currentTab: 'keepers', mobile: true })

    const links = Array.from(container.querySelectorAll('nav[aria-label="Primary mobile navigation"] a'))
    const current = links.find(a => a.getAttribute('aria-current') === 'page')
    expect(current?.textContent?.trim()).toBe('Keepers')

    for (const link of links.filter(a => a !== current)) {
      expect(link.hasAttribute('aria-current')).toBe(false)
    }
  })

  it('opens the operational drawer from the mobile More tab', () => {
    renderNav({ mobile: true, drawerOpen: false })

    const more = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.includes('More')) as HTMLElement
    expect(more).toBeTruthy()
    more.click()

    expect(onToggleDrawer).toHaveBeenCalledTimes(1)
  })

  it('hides mobile tabs while the drawer overlay is open', () => {
    renderNav({ mobile: true, drawerOpen: true, collapsed: true })

    expect(container.querySelector('nav[aria-label="Primary mobile navigation"]')).toBeNull()
    const rail = container.querySelector('[data-testid="dashboard-nav-rail"]')
    expect(rail?.className).toContain('block')
    expect(rail?.className).toContain('fixed')

    const overlay = container.querySelector('[data-testid="dashboard-nav-rail-overlay"]') as HTMLElement | null
    expect(overlay).not.toBeNull()
    overlay!.click()
    expect(onCloseDrawer).toHaveBeenCalledTimes(1)

    expect(container.querySelector('.nb-sub')?.textContent).toContain('Cockpit')
  })

  it('keeps operational routes in the mobile More drawer', () => {
    renderNav({ mobile: true, drawerOpen: true })

    const railText = container.querySelector('[data-testid="dashboard-nav-rail"]')?.textContent ?? ''
    expect(railText).toContain('Monitor')
    expect(railText).toContain('Command')
    expect(railText).toContain('Lab')
    expect(railText).toContain('Logs')
    expect(container.querySelector('.nav-footer .nav-footer-settings')?.textContent).toContain('Settings')
  })

  it('does not render mobile tabs in desktop mode', () => {
    renderNav({ mobile: false, drawerOpen: false, collapsed: true })

    expect(container.querySelector('nav[aria-label="Primary mobile navigation"]')).toBeNull()
    const rail = container.querySelector('[data-testid="dashboard-nav-rail"]')
    expect(rail).not.toBeNull()
    // Collapsed rail width matches the keeper-v2 prototype --nav-w: 58px
    // (v2.css:232) — literal w-[58px], not Tailwind w-14 (56px).
    expect(rail?.className).toContain('w-[58px]')
    expect(rail?.className).toContain('max-[1100px]:hidden')
  })

  it('renders the prototype icon-rail brand logo box when collapsed', () => {
    renderNav({ mobile: false, drawerOpen: false, collapsed: true })

    const rail = container.querySelector('[data-testid="dashboard-nav-rail"]')
    expect(rail?.getAttribute('data-collapsed')).toBe('true')
    // Collapsed brand = prototype .nav-home 38x38 monogram box (v2.css:242).
    const brandHome = container.querySelector('.nav-brand .nav-home')
    expect(brandHome).not.toBeNull()
    expect(brandHome?.textContent?.trim()).toBe('M')
  })

  it('hides mobile tabs while reading keeper chat', () => {
    renderNav({ mobile: true, drawerOpen: false, hideMobileTabs: true })

    expect(container.querySelector('nav[aria-label="Primary mobile navigation"]')).toBeNull()
    expect(container.querySelector('[data-testid="dashboard-nav-rail"]')).not.toBeNull()
  })

  it('guarantees a 44px minimum touch target on every mobile tab item', () => {
    renderNav({ mobile: true })

    const interactives = container.querySelectorAll('nav[aria-label="Primary mobile navigation"] a, nav[aria-label="Primary mobile navigation"] button')
    expect(interactives.length).toBe(PRIMARY_LABELS.length + 1)
    for (const el of interactives) {
      expect(el.className).toContain('min-h-[44px]')
    }
  })

  it('passes axe accessibility for the closed mobile rail state', async () => {
    renderNav({ mobile: true, drawerOpen: false })
    expect(await axe(container)).toHaveNoViolations()
  })
})

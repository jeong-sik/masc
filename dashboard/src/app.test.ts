// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { App, shouldSuppressFloatingChrome, shouldUseCompactDashboardChrome } from './app'
import { route } from './router'
import { serverStatus, shellCounts } from './store'
import { selectedKeeper } from './components/keeper-detail-state'

describe('App v2 header chrome', () => {
  let container: HTMLDivElement
  const originalHash = window.location.hash

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = originalHash
    route.value = { tab: 'overview', params: {}, postId: null }
    shellCounts.value = null
    serverStatus.value = null
    selectedKeeper.value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    window.location.hash = originalHash
    route.value = { tab: 'overview', params: {}, postId: null }
    shellCounts.value = null
    serverStatus.value = null
    selectedKeeper.value = null
  })

  function renderApp() {
    render(h(App, {}), container)
  }

  it('renders v2 app shell wrapper with tweak attributes (v2 dark default, no data-theme)', () => {
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app).not.toBeNull()
    expect(app?.hasAttribute('data-theme')).toBe(false)
    expect(app?.getAttribute('data-density')).toBe('regular')
    expect(app?.getAttribute('data-motion')).toBe('subtle')
    expect(app?.getAttribute('data-bubble')).toBe('card')
    expect(app?.hasAttribute('data-surface')).toBe(true)
  })

  it('defaults to the v2 dark skin (no data-theme on the dashboard root)', () => {
    // Theme ownership lives on <html> (bootstrapped by main.ts, toggled by
    // ThemeSwitch). The app root no longer hard-codes a theme, so the default
    // is the keeper-v2 dark skin; paper / styleseed are opt-in light themes.
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app?.hasAttribute('data-theme')).toBe(false)
  })

  it('renders v2 shell header and health strip scopes', () => {
    renderApp()
    expect(container.querySelector('header.v2-shell-header')).not.toBeNull()
    expect(container.querySelector('[data-testid="dashboard-health-strip"].v2-health-strip')).not.toBeNull()
  })

  it('renders v2 header structural classes', () => {
    renderApp()
    expect(container.querySelector('.v2-header-brand')).not.toBeNull()
    expect(container.querySelector('.v2-header-mark')).not.toBeNull()
    expect(container.querySelector('.v2-header-crumb')).not.toBeNull()
    // The global chrome no longer renders a page title: surface-level headers
    // own the title source of truth, so the shell header carries only the crumb.
    expect(container.querySelector('.v2-header-title')).toBeNull()
    expect(container.querySelector('.v2-header-actions')).not.toBeNull()
    expect(container.querySelector('.v2-shell-tabs')).toBeNull()
    expect(container.querySelector('.v2-app-header-status')).not.toBeNull()
    expect(container.querySelector('.v2-statchip.live')).not.toBeNull()
  })

  it('renders keeper breadcrumb tail and visible Korean desktop status chips', () => {
    window.innerWidth = 1280
    route.value = { tab: 'keepers', params: { keeper: 'albini' }, postId: null }
    shellCounts.value = {
      agents: 0,
      tasks: 0,
      keepers: 7,
      total_runtimes: 0,
      configured_keepers: 7,
    }
    serverStatus.value = {} as NonNullable<typeof serverStatus.value>
    renderApp()

    const crumb = container.querySelector('.v2-header-crumb')
    expect(crumb?.textContent).toContain('Keepers')
    expect(crumb?.textContent).toContain('albini')

    const status = container.querySelector('.v2-app-header-status') as HTMLElement | null
    expect(status).not.toBeNull()
    expect(status?.classList.contains('flex')).toBe(true)
    expect(status?.classList.contains('hidden')).toBe(false)
    expect(status?.textContent).toContain('7 실행 중')
    expect(status?.textContent).toContain('스케줄러')
    expect(status?.textContent).toContain('정상')
    const liveChip = status?.querySelector('.v2-statchip.live') as HTMLElement | null
    expect(liveChip?.getAttribute('title')).toBe('실행 중인 keeper 수 (shell 스냅샷 기준)')
    const schedulerChip = Array.from(status?.querySelectorAll('.v2-statchip') ?? [])
      .find(chip => chip !== liveChip) as HTMLElement | undefined
    expect(schedulerChip?.getAttribute('title')).toBe('서버 상태로 추정한 스케줄러 상태')
    expect(
      status?.querySelector('.v2-statchip.live span')?.classList.contains('motion-safe:animate-pulse'),
    ).toBe(true)
  })

  it('falls back to selectedKeeper for the breadcrumb tail when no route keeper param', () => {
    // Mirrors keeper-detail-page resolution tier 2: with no route keeper param
    // the crumb still tracks the keeper the chat is showing via selectedKeeper.
    window.innerWidth = 1280
    route.value = { tab: 'keepers', params: {}, postId: null }
    selectedKeeper.value = { name: 'grimja' } as NonNullable<typeof selectedKeeper.value>
    renderApp()

    const crumb = container.querySelector('.v2-header-crumb')
    expect(crumb?.textContent).toContain('Keepers')
    expect(crumb?.textContent).toContain('grimja')
    // No dangling slash when a tail is present.
    expect(crumb?.textContent?.trim().endsWith('/')).toBe(false)
  })

  it('renders the main stage as a StyleSeed card (white, rounded-2xl, soft shadow)', () => {
    window.innerWidth = 1280
    renderApp()

    const main = container.querySelector('#main-content') as HTMLElement | null
    expect(main).not.toBeNull()
    expect(main?.classList.contains('v2-body')).toBe(true)

    const cls = main?.className ?? ''
    expect(cls).toContain('bg-[var(--ss-card)]')
    expect(cls).toContain('rounded-[var(--ss-radius-card)]')
    expect(cls).toContain('shadow-[var(--ss-shadow-card)]')
    expect(cls).toContain('border-[var(--ss-border)]')
  })

  it('renders health chips with the shared chip class', () => {
    renderApp()
    const chip = container.querySelector('.dashboard-health-chip')
    expect(chip).not.toBeNull()
  })

  it('sets data-mobile based on the viewport width', () => {
    window.innerWidth = 900
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app?.getAttribute('data-mobile')).toBe('true')
  })

  it('does not set data-mobile above the v2 shell breakpoint', () => {
    window.innerWidth = 901
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app?.getAttribute('data-mobile')).toBe('false')
  })

  it('uses a 44x44 mobile menu button touch target', () => {
    window.innerWidth = 900
    renderApp()

    const menuButton = container.querySelector('button[aria-controls="dashboard-side-rail"]') as HTMLElement | null
    expect(menuButton).not.toBeNull()
    expect(menuButton?.classList.contains('size-11')).toBe(true)
  })

  it('hides mobile nav tabs when the mobile side-rail drawer is open', async () => {
    window.innerWidth = 900
    renderApp()

    const menuButton = container.querySelector('button[aria-controls="dashboard-side-rail"]') as HTMLElement | null
    expect(menuButton).not.toBeNull()
    menuButton!.click()

    await waitFor(() => {
      expect(container.querySelector('nav[aria-label="Primary mobile navigation"]')).toBeNull()
    })
  })

  it('uses the header Copilot control instead of a floating FAB on mobile', () => {
    window.innerWidth = 900
    renderApp()

    expect(container.querySelector('[data-testid="copilot-dock-topbar-button"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="copilot-dock-fab"]')).toBeNull()
  })

  it('hides mobile nav tabs on keeper detail routes', () => {
    window.location.hash = '#monitoring/agents?keeper=sangsu'
    route.value = { tab: 'monitoring', params: { section: 'agents', keeper: 'sangsu' }, postId: null }
    window.innerWidth = 900
    renderApp()

    const bottomNav = container.querySelector('nav[aria-label="Primary mobile navigation"]')
    expect(bottomNav).toBeNull()
  })

  it('renders the left side rail on desktop', () => {
    window.innerWidth = 1280
    renderApp()

    const rail = container.querySelector('#dashboard-side-rail')
    expect(rail).not.toBeNull()
    expect(rail?.classList.contains('v2-shell-rail')).toBe(true)
    expect(rail?.classList.contains('max-[1100px]:hidden')).toBe(true)
  })

  it('does not collapse the left rail out of view on desktop', () => {
    window.innerWidth = 1280
    renderApp()

    const rail = container.querySelector('#dashboard-side-rail') as HTMLElement
    expect(rail).not.toBeNull()
    const cls = Array.from(rail.classList).join(' ')
    // The desktop rail must carry a fixed width (w-14 or w-55), not w-full.
    expect(cls).toMatch(/\bw-14\b|\bw-55\b/)
    expect(cls).not.toMatch(/\bmax-h-75\b/)
  })

  it('keeps main content scrollable', () => {
    window.innerWidth = 1280
    renderApp()

    const main = container.querySelector('#main-content')
    expect(main).not.toBeNull()
    expect(main?.classList.contains('overflow-hidden')).toBe(true)

    const scroll = main?.querySelector('.dashboard-main-scroll')
    expect(scroll).not.toBeNull()
    expect(scroll?.classList.contains('overflow-y-auto')).toBe(true)
    expect(scroll?.classList.contains('h-full')).toBe(true)
  })

  it('toggles the mobile side-rail drawer', async () => {
    window.innerWidth = 900
    renderApp()

    const rail = container.querySelector('#dashboard-side-rail') as HTMLElement | null
    expect(rail).not.toBeNull()

    const menuButton = container.querySelector('button[aria-controls="dashboard-side-rail"]') as HTMLElement | null
    expect(menuButton).not.toBeNull()
    menuButton!.click()

    // DashboardNavRail owns the mobile drawer contract: opening swaps the rail
    // from the hidden mobile state into an explicit block drawer.
    await waitFor(() => {
      expect(rail?.classList.contains('block')).toBe(true)
      expect(rail?.classList.contains('hidden')).toBe(false)
      expect(container.querySelector('[data-testid="dashboard-status-tray"]')).toBeNull()
      expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).toBeNull()
    })
  })

  it('hides floating status and focus chrome on prototype primary surfaces', () => {
    window.innerWidth = 1280
    window.location.hash = '#overview'
    route.value = { tab: 'overview', params: {}, postId: null }
    renderApp()

    expect(container.querySelector('[data-testid="dashboard-status-tray"]')).toBeNull()
    expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).toBeNull()
  })

  it('keeps floating status and focus chrome on operational surfaces', () => {
    window.innerWidth = 1280
    window.location.hash = '#monitoring/agents'
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
    renderApp()

    expect(container.querySelector('[data-testid="dashboard-status-tray"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).not.toBeNull()
  })

  it('focus mode does not permanently hide the rail', async () => {
    window.innerWidth = 1280
    window.location.hash = '#monitoring/agents'
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
    renderApp()

    // Rail should be visible initially.
    expect(container.querySelector('#dashboard-side-rail')).not.toBeNull()

    const focusButton = container.querySelector('[data-testid="dashboard-focus-mode-toggle"]') as HTMLElement | null
    expect(focusButton).not.toBeNull()
    focusButton!.click()

    // Wait for Preact to re-render after the persistent signal update.
    await waitFor(() => {
      expect(container.querySelector('#dashboard-side-rail')).toBeNull()
    })
    expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).not.toBeNull()

    // Toggling back restores the rail.
    focusButton!.click()
    await waitFor(() => {
      expect(container.querySelector('#dashboard-side-rail')).not.toBeNull()
    })
  })
})

describe('shouldSuppressFloatingChrome', () => {
  it('suppresses floating chrome for prototype primary surfaces', () => {
    expect(shouldSuppressFloatingChrome({
      currentTab: 'overview',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
    expect(shouldSuppressFloatingChrome({
      currentTab: 'connectors',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
    expect(shouldSuppressFloatingChrome({
      currentTab: 'logs',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
  })

  it('keeps floating chrome for operational surfaces unless a shell overlay is active', () => {
    expect(shouldSuppressFloatingChrome({
      currentTab: 'monitoring',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(false)
    expect(shouldSuppressFloatingChrome({
      currentTab: 'monitoring',
      keeperDetailMode: false,
      mobileDrawerOpen: true,
    })).toBe(true)
  })
})

describe('shouldUseCompactDashboardChrome', () => {
  it('keeps the standard shell for keeper detail routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: false,
    })).toBe(false)
  })

  it('uses compact chrome for widget solo routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: true,
      focusMode: false,
    })).toBe(true)
  })

  it('uses compact chrome for focus mode', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: true,
    })).toBe(true)
  })
})

// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { App, shouldUseCompactDashboardChrome } from './app'

describe('App v2 header chrome', () => {
  let container: HTMLDivElement
  const originalHash = window.location.hash

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = originalHash
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    window.location.hash = originalHash
  })

  function renderApp() {
    render(h(App, {}), container)
  }

  it('renders v2 app shell wrapper with StyleSeed theme and tweak attributes', () => {
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app).not.toBeNull()
    expect(app?.getAttribute('data-theme')).toBe('styleseed')
    expect(app?.getAttribute('data-density')).toBe('regular')
    expect(app?.getAttribute('data-motion')).toBe('subtle')
    expect(app?.getAttribute('data-bubble')).toBe('card')
    expect(app?.hasAttribute('data-surface')).toBe(true)
  })

  it('sets the default StyleSeed theme on the dashboard root', () => {
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app?.getAttribute('data-theme')).toBe('styleseed')
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
    expect(container.querySelector('.v2-header-title')).not.toBeNull()
    expect(container.querySelector('.v2-header-actions')).not.toBeNull()
    expect(container.querySelector('.v2-shell-tabs')).not.toBeNull()
    expect(container.querySelector('.v2-app-header-status')).not.toBeNull()
    expect(container.querySelector('.v2-statchip.live')).not.toBeNull()
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
    window.innerWidth = 760
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app?.getAttribute('data-mobile')).toBe('true')
  })

  it('uses a 44x44 mobile menu button touch target', () => {
    window.innerWidth = 760
    renderApp()

    const menuButton = container.querySelector('button[aria-controls="dashboard-side-rail"]') as HTMLElement | null
    expect(menuButton).not.toBeNull()
    expect(menuButton?.classList.contains('size-11')).toBe(true)
  })

  it('hides MobileBottomBar when the mobile side-rail drawer is open', async () => {
    window.innerWidth = 760
    renderApp()

    const menuButton = container.querySelector('button[aria-controls="dashboard-side-rail"]') as HTMLElement | null
    expect(menuButton).not.toBeNull()
    menuButton!.click()

    await waitFor(() => {
      expect(container.querySelector('nav[aria-label="Primary mobile navigation"]')).toBeNull()
    })
  })

  it('hides MobileBottomBar on keeper detail routes', () => {
    window.location.hash = '#monitoring/agents?keeper=sangsu'
    window.innerWidth = 760
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
    window.innerWidth = 760
    renderApp()

    const rail = container.querySelector('#dashboard-side-rail') as HTMLElement | null
    expect(rail).not.toBeNull()

    const menuButton = container.querySelector('button[aria-controls="dashboard-side-rail"]') as HTMLElement | null
    expect(menuButton).not.toBeNull()
    menuButton!.click()

    await waitFor(() => {
      expect(rail?.classList.contains('max-[768px]:hidden')).toBe(false)
    })
  })

  it('focus mode does not permanently hide the rail', async () => {
    window.innerWidth = 1280
    window.location.hash = '#overview'
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

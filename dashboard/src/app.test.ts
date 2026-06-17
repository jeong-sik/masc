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

  it('renders v2 app shell wrapper with density/motion/bubble/surface attributes', () => {
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app).not.toBeNull()
    expect(app?.getAttribute('data-density')).toBe('regular')
    expect(app?.getAttribute('data-motion')).toBe('subtle')
    expect(app?.getAttribute('data-bubble')).toBe('card')
    expect(app?.hasAttribute('data-surface')).toBe(true)
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

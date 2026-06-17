// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { App, shouldUseCompactDashboardChrome } from './app'

describe('App v2 header chrome', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    render(h(App, {}), container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders v2 app shell wrapper with density/motion/bubble/surface attributes', () => {
    const app = container.querySelector('.v2-app')
    expect(app).not.toBeNull()
    expect(app?.getAttribute('data-density')).toBe('regular')
    expect(app?.getAttribute('data-motion')).toBe('subtle')
    expect(app?.getAttribute('data-bubble')).toBe('card')
    expect(app?.hasAttribute('data-surface')).toBe(true)
  })

  it('renders v2 shell header and health strip scopes', () => {
    expect(container.querySelector('header.v2-shell-header')).not.toBeNull()
    expect(container.querySelector('[data-testid="dashboard-health-strip"].v2-health-strip')).not.toBeNull()
  })

  it('renders v2 header structural classes', () => {
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
    const chip = container.querySelector('.dashboard-health-chip')
    expect(chip).not.toBeNull()
  })
})

describe('shouldUseCompactDashboardChrome', () => {
  it('uses compact chrome for keeper detail routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: false,
      keeperDetailMode: true,
    })).toBe(true)
  })

  it('keeps the standard shell for normal dashboard routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: false,
      keeperDetailMode: false,
    })).toBe(false)
  })
})

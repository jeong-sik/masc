// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MobileBottomBar } from './mobile-nav'

const navigate = vi.fn()
const hashForRoute = vi.fn((tab: string, params?: Record<string, string>) => {
  return params ? `#${tab}?${new URLSearchParams(params)}` : `#${tab}`
})

vi.mock('../router', () => ({
  navigate: (...args: Parameters<typeof navigate>) => navigate(...args),
  hashForRoute: (...args: Parameters<typeof hashForRoute>) => hashForRoute(...args),
}))

const PRIMARY_LABELS = ['Overview', 'Monitor', 'Command', 'Workspace'] as const

describe('MobileBottomBar', () => {
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

  it('renders the 4 primary surfaces plus a More button', () => {
    render(html`<${MobileBottomBar} currentTab="monitoring" onMenuToggle=${() => {}} />`, container)

    const nav = container.querySelector('nav[aria-label="Primary mobile navigation"]')
    expect(nav).not.toBeNull()

    const labels = Array.from(container.querySelectorAll('a, button'))
      .map(el => el.textContent?.trim())
    for (const label of PRIMARY_LABELS) {
      expect(labels).toContain(label)
    }
    expect(labels).toContain('More')
  })

  it('marks only the current surface with aria-current=page', () => {
    render(html`<${MobileBottomBar} currentTab="command" onMenuToggle=${() => {}} />`, container)

    const links = Array.from(container.querySelectorAll('a'))
    const current = links.find(a => a.getAttribute('aria-current') === 'page')
    expect(current?.textContent?.trim()).toBe('Command')

    for (const link of links.filter(a => a !== current)) {
      expect(link.hasAttribute('aria-current')).toBe(false)
    }
  })

  it('invokes onMenuToggle when the More button is clicked', () => {
    const onMenuToggle = vi.fn()
    render(html`<${MobileBottomBar} currentTab="overview" onMenuToggle=${onMenuToggle} />`, container)

    const more = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.includes('More')) as HTMLElement
    expect(more).toBeTruthy()
    more.click()

    expect(onMenuToggle).toHaveBeenCalledTimes(1)
  })

  it('guarantees a 44px minimum touch target on every interactive item', () => {
    render(html`<${MobileBottomBar} currentTab="overview" onMenuToggle=${() => {}} />`, container)

    const interactives = container.querySelectorAll('a, button')
    expect(interactives.length).toBe(PRIMARY_LABELS.length + 1) // 4 surfaces + More
    for (const el of interactives) {
      expect(el.className).toContain('min-h-[44px]')
    }
  })

  it('passes axe accessibility', async () => {
    render(html`<${MobileBottomBar} currentTab="overview" onMenuToggle=${() => {}} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

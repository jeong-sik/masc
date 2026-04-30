import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { RouteLink } from './route-link'

const navigate = vi.fn()
const hashForRoute = vi.fn((tab: string, params?: Record<string, string>) => {
  return params ? `#${tab}?${new URLSearchParams(params)}` : `#${tab}`
})

vi.mock('../../router', () => ({
  navigate: (...args: any[]) => navigate(...args),
  hashForRoute: (...args: any[]) => hashForRoute(...args),
}))

describe('RouteLink', () => {
  it('renders anchor with href', () => {
    const container = document.createElement('div')
    render(h(RouteLink, { tab: 'home' as any }, 'Home'), container)
    const a = container.querySelector('a')
    expect(a?.getAttribute('href')).toBe('#home')
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(h(RouteLink, { tab: 'home' as any }, 'Home'), container)
    expect(container.textContent).toContain('Home')
  })

  it('applies class', () => {
    const container = document.createElement('div')
    render(h(RouteLink, { tab: 'home' as any, class: 'my-link' }, 'Home'), container)
    const a = container.querySelector('a')
    expect(a?.classList.contains('my-link')).toBe(true)
  })

  it('applies title', () => {
    const container = document.createElement('div')
    render(h(RouteLink, { tab: 'home' as any, title: 'Go home' }, 'Home'), container)
    const a = container.querySelector('a')
    expect(a?.getAttribute('title')).toBe('Go home')
  })

  it('applies aria-current', () => {
    const container = document.createElement('div')
    render(h(RouteLink, { tab: 'home' as any, ariaCurrent: 'page' }, 'Home'), container)
    const a = container.querySelector('a')
    expect(a?.getAttribute('aria-current')).toBe('page')
  })

  it('calls navigate on left click', async () => {
    const container = document.createElement('div')
    render(h(RouteLink, { tab: 'home' as any }, 'Home'), container)
    const a = container.querySelector('a') as HTMLElement
    a.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(navigate).toHaveBeenCalledWith('home', undefined)
  })

})

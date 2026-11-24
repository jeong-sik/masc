// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { SurfaceHeader } from './surface-header'
import { route } from '../../router'

describe('SurfaceHeader', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    route.value = { tab: 'overview', params: {}, postId: null }
  })

  it.each([
    ['monitoring', 'Runtime'],
  ] as const)('renders the %s surface title as the primary h1', (tab, label) => {
    route.value = { tab, params: {}, postId: null }
    render(h(SurfaceHeader, {}), container)
    const h1 = container.querySelector('header.v2-surface-header h1')
    expect(h1?.textContent?.trim()).toBe(label)
  })

  it('carries the shared copy affordances', () => {
    route.value = { tab: 'monitoring', params: {}, postId: null }
    render(h(SurfaceHeader, {}), container)
    expect(container.querySelector('.v2-surface-header-actions')).not.toBeNull()
  })

  it('renders parent breadcrumbs for section routes', () => {
    route.value = { tab: 'monitoring', params: { section: 'runtime' }, postId: null }
    render(h(SurfaceHeader, {}), container)
    const breadcrumb = container.querySelector('[data-testid="surface-breadcrumb"]')
    expect(breadcrumb).not.toBeNull()
    expect(breadcrumb?.getAttribute('data-surface-breadcrumb')).toBe('true')
    expect(breadcrumb?.textContent).toContain('Monitor')
    expect(breadcrumb?.textContent).toContain('Runtime')
  })
})

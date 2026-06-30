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

  // Each surface that does not render a richer bespoke header (monitoring,
  // command, lab) opts into SurfaceHeader, which surfaces the current
  // section/view label as the single primary h1. These labels match what the
  // former generic SurfaceLead rendered (same currentSectionForRoute logic).
  // The board surface renders no title header (matches the prototype), so it
  // is intentionally absent here.
  it.each([
    ['monitoring', 'Keeper Fleet'],
    ['command', 'Actions'],
    ['lab', 'Tools'],
  ] as const)('renders the %s surface title as the primary h1', (tab, label) => {
    route.value = { tab, params: {}, postId: null }
    render(h(SurfaceHeader, {}), container)
    const h1 = container.querySelector('header.v2-surface-header h1')
    expect(h1?.textContent?.trim()).toBe(label)
  })

  it('carries the shared copy + solo-view affordances', () => {
    route.value = { tab: 'monitoring', params: {}, postId: null }
    render(h(SurfaceHeader, {}), container)
    expect(container.querySelector('.v2-surface-header-actions')).not.toBeNull()
    expect(container.querySelector('[data-testid="dashboard-widget-solo-link"]')).not.toBeNull()
  })

  it('renders parent breadcrumbs for section routes', () => {
    route.value = { tab: 'lab', params: { section: 'keeper-memory-health' }, postId: null }
    render(h(SurfaceHeader, {}), container)
    const breadcrumb = container.querySelector('[data-testid="surface-breadcrumb"]')
    expect(breadcrumb).not.toBeNull()
    expect(breadcrumb?.getAttribute('data-surface-breadcrumb')).toBe('true')
    expect(breadcrumb?.textContent).toContain('Lab')
    expect(breadcrumb?.textContent).toContain('키퍼 메모리 상태')
  })

  it('does not duplicate the body header in widget solo mode', () => {
    route.value = { tab: 'lab', params: { section: 'tools', solo: '1' }, postId: null }
    render(h(SurfaceHeader, {}), container)
    expect(container.querySelector('.v2-surface-header')).toBeNull()
    expect(container.querySelector('[data-testid="dashboard-widget-solo-link"]')).toBeNull()
  })
})

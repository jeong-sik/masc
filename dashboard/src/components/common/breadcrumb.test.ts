// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Breadcrumb } from './breadcrumb'

describe('Breadcrumb', () => {
  it('renders a breadcrumb nav and ordered path', () => {
    const container = document.createElement('div')
    render(h(Breadcrumb, {
      items: [
        { label: 'Command', href: '#command' },
        { label: 'Operations' },
      ],
    }), container)

    const nav = container.querySelector('nav')
    expect(nav?.getAttribute('aria-label')).toBe('Breadcrumb')
    expect(container.querySelectorAll('ol > li').length).toBe(2)
    expect(container.textContent).toContain('Command')
    expect(container.textContent).toContain('Operations')
  })

  it('marks the terminal crumb as current', () => {
    const container = document.createElement('div')
    render(h(Breadcrumb, {
      items: [
        { label: 'Connectors', href: '#connectors' },
        { label: 'Discord' },
      ],
    }), container)

    const current = container.querySelector('[aria-current="page"]')
    expect(current).not.toBeNull()
    expect(current?.textContent).toBe('Discord')
  })

  it('uses an explicit current crumb when provided', () => {
    const container = document.createElement('div')
    render(h(Breadcrumb, {
      items: [
        { label: 'Workspace' },
        { label: 'Board', current: true },
        { label: 'Task' },
      ],
    }), container)

    const current = container.querySelectorAll('[aria-current="page"]')
    expect(current.length).toBe(1)
    expect(current[0]?.textContent).toBe('Board')
  })

  it('keeps separators decorative', () => {
    const container = document.createElement('div')
    render(h(Breadcrumb, {
      items: [
        { label: 'A' },
        { label: 'B' },
        { label: 'C' },
      ],
    }), container)

    const separators = container.querySelectorAll('[aria-hidden="true"]')
    expect(separators.length).toBe(2)
    expect(separators[0]?.textContent).toBe('›')
  })

  it('calls item onClick for interactive crumbs', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(Breadcrumb, {
      items: [
        { label: 'Command', href: '#command', onClick },
        { label: 'Operations' },
      ],
    }), container)

    ;(container.querySelector('a') as HTMLAnchorElement).click()
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('applies test id, custom aria label, and surface marker', () => {
    const container = document.createElement('div')
    render(h(Breadcrumb, {
      items: [{ label: 'Operations' }],
      ariaLabel: 'Page path',
      testId: 'surface-breadcrumb',
      dataSurfaceBreadcrumb: true,
    }), container)

    const nav = container.querySelector('[data-testid="surface-breadcrumb"]')
    expect(nav).not.toBeNull()
    expect(nav?.getAttribute('aria-label')).toBe('Page path')
    expect(nav?.getAttribute('data-surface-breadcrumb')).toBe('true')
  })

  it('renders nothing when the trail is empty', () => {
    const container = document.createElement('div')
    render(h(Breadcrumb, { items: [] }), container)
    expect(container.querySelector('nav')).toBeNull()
  })
})

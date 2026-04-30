// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { BreadcrumbHistory } from './breadcrumb-history'

describe('BreadcrumbHistory a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeItems = (): import('./breadcrumb-history').BreadcrumbItem[] => [
    { id: 'b1', label: 'Home', timestamp: Date.now() - 60000 },
    { id: 'b2', label: 'Project', active: true },
    { id: 'b3', label: 'Task' },
  ]

  it('renders accessibly with items', async () => {
    render(html`<${BreadcrumbHistory} items=${makeItems()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when empty', async () => {
    render(html`<${BreadcrumbHistory} items=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has nav role', () => {
    render(html`<${BreadcrumbHistory} items=${makeItems()} />`, container)
    expect(container.querySelector('nav')).not.toBeNull()
  })

  it('renders listitems', () => {
    render(html`<${BreadcrumbHistory} items=${makeItems()} />`, container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(3)
  })

  it('marks active item with aria-current', () => {
    render(html`<${BreadcrumbHistory} items=${makeItems()} />`, container)
    const active = container.querySelector('[aria-current="page"]')
    expect(active).not.toBeNull()
    expect(active?.textContent).toContain('Project')
  })

  it('calls onNavigate when clicked', () => {
    const onNavigate = vi.fn()
    render(
      html`<${BreadcrumbHistory} items=${makeItems()} onNavigate=${onNavigate} />`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    expect(onNavigate).toHaveBeenCalledWith('b1')
  })
})

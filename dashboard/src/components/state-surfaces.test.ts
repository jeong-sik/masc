// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { EmptyState, ErrorState, LoadingState } from './state-surfaces'

describe('EmptyState', () => {
  it('renders glyph, title and hint', () => {
    const container = document.createElement('div')
    render(
      html`<${EmptyState} glyph="◌" title="Nothing here" hint="Add an item to get started" />`,
      container,
    )

    const root = container.querySelector('[data-testid="empty-state"]')
    expect(root).not.toBeNull()
    expect(container.textContent).toContain('Nothing here')
    expect(container.textContent).toContain('Add an item to get started')
    expect(container.querySelector('.kv-state-g')?.textContent).toBe('◌')
  })

  it('renders an action button that calls onAction', () => {
    const onAction = vi.fn()
    const container = document.createElement('div')
    render(
      html`<${EmptyState} title="Empty" action="Create" onAction=${onAction} />`,
      container,
    )

    const button = container.querySelector('button')
    expect(button).not.toBeNull()
    button!.click()
    expect(onAction).toHaveBeenCalledTimes(1)
  })

  it('omits action when onAction is missing', () => {
    const container = document.createElement('div')
    render(html`<${EmptyState} title="Empty" action="Create" />`, container)
    expect(container.querySelector('button')).toBeNull()
  })
})

describe('ErrorState', () => {
  it('renders glyph, title and detail', () => {
    const container = document.createElement('div')
    render(
      html`<${ErrorState} title="Failed" detail="connection refused" />`,
      container,
    )

    const root = container.querySelector('[data-testid="error-state"]')
    expect(root).not.toBeNull()
    expect(container.textContent).toContain('Failed')
    expect(container.textContent).toContain('connection refused')
    expect(container.querySelector('.kv-state-g')?.textContent).toBe('⚠')
  })

  it('renders a retry button that calls onAction', () => {
    const onAction = vi.fn()
    const container = document.createElement('div')
    render(html`<${ErrorState} title="Failed" onAction=${onAction} />`, container)

    const button = container.querySelector('button')
    expect(button).not.toBeNull()
    expect(button!.textContent).toContain('다시 시도')
    button!.click()
    expect(onAction).toHaveBeenCalledTimes(1)
  })

  it('uses custom action label', () => {
    const container = document.createElement('div')
    render(html`<${ErrorState} title="Failed" action="Reload" onAction=${() => {}} />`, container)
    expect(container.querySelector('button')?.textContent).toContain('Reload')
  })
})

describe('LoadingState', () => {
  it('renders the default title and skeleton rows', () => {
    const container = document.createElement('div')
    render(html`<${LoadingState} />`, container)

    expect(container.querySelector('[data-testid="loading-state"]')).not.toBeNull()
    expect(container.textContent).toContain('불러오는 중…')
    expect(container.querySelectorAll('.kv-skel-row').length).toBe(3)
  })

  it('renders a custom title and row count', () => {
    const container = document.createElement('div')
    render(html`<${LoadingState} title="Loading posts…" rows=${5} />`, container)

    expect(container.textContent).toContain('Loading posts…')
    expect(container.querySelectorAll('.kv-skel-row').length).toBe(5)
  })
})

afterEach(() => {
  document.body.innerHTML = ''
})

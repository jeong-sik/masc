// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { EmptyState } from './empty-state'

describe('EmptyState (via empty-state re-export)', () => {
  it('renders with default props', () => {
    const container = document.createElement('div')
    render(h(EmptyState), container)
    const el = container.querySelector('[role="status"]')
    expect(el).not.toBeNull()
  })

  it('renders message text', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { message: 'No items found' }), container)
    expect(container.textContent).toContain('No items found')
  })

  it('renders icon when provided', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { icon: '\u{1F50D}' }), container)
    expect(container.textContent).toContain('\u{1F50D}')
  })

  it('prefers children over message', () => {
    const container = document.createElement('div')
    render(
      h(EmptyState, { message: 'parent-msg' }, h('span', null, 'child-node')),
      container,
    )
    expect(container.textContent).toContain('child-node')
  })

  it('applies compact padding', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { compact: true }), container)
    const el = container.querySelector('[role="status"]')
    expect(el?.classList.contains('py-4')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { class: 'custom-empty' }), container)
    const el = container.querySelector('[role="status"]')
    expect(el?.classList.contains('custom-empty')).toBe(true)
  })

  it('renders action slot', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { action: h('button', null, 'Retry') }), container)
    expect(container.textContent).toContain('Retry')
  })
})

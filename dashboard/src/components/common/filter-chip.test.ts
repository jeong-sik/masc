import { describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { FilterChip } from './filter-chip'

describe('FilterChip', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(html`<${FilterChip}>All<//>`, container)
    expect(container.textContent).toContain('All')
  })

  it('renders count', () => {
    const container = document.createElement('div')
    render(html`<${FilterChip} count=${12}>All<//>`, container)
    expect(container.textContent).toContain('12')
  })

  it('applies active class and aria-pressed', () => {
    const container = document.createElement('div')
    render(html`<${FilterChip} active=${true}>Running<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('on')).toBe(true)
    expect(el?.getAttribute('aria-pressed')).toBe('true')
  })

  it('is not active by default', () => {
    const container = document.createElement('div')
    render(html`<${FilterChip}>Running<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('on')).toBe(false)
    expect(el?.getAttribute('aria-pressed')).toBe('false')
  })

  it('calls onClick when pressed', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(html`<${FilterChip} onClick=${onClick}>Blocked<//>`, container)
    const el = container.querySelector('button') as HTMLElement
    el.click()
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(html`<${FilterChip} class="my-chip">All<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('my-chip')).toBe(true)
  })
})

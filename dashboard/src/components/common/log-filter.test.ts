// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { LogFilter } from './log-filter'

describe('LogFilter', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(html`<${LogFilter}>All<//>`, container)
    expect(container.textContent).toContain('All')
  })

  it('applies active class and aria-pressed', () => {
    const container = document.createElement('div')
    render(html`<${LogFilter} active=${true}>Error<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('log-f')).toBe(true)
    expect(el?.classList.contains('on')).toBe(true)
    expect(el?.getAttribute('aria-pressed')).toBe('true')
  })

  it('is not active by default', () => {
    const container = document.createElement('div')
    render(html`<${LogFilter}>Warn<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('on')).toBe(false)
    expect(el?.getAttribute('aria-pressed')).toBe('false')
  })

  it('calls onClick when pressed', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(html`<${LogFilter} onClick=${onClick}>Info<//>`, container)
    const el = container.querySelector('button') as HTMLElement
    el.click()
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('passes through data attributes', () => {
    const container = document.createElement('div')
    render(html`<${LogFilter} data-log-level="error">Error<//>`, container)
    const el = container.querySelector('button')
    expect(el?.getAttribute('data-log-level')).toBe('error')
  })

  it('applies custom class alongside base class', () => {
    const container = document.createElement('div')
    render(html`<${LogFilter} class="v2-sidecar-log-level-pill">All<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('log-f')).toBe(true)
    expect(el?.classList.contains('v2-sidecar-log-level-pill')).toBe(true)
  })
})

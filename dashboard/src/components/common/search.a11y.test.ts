// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Search } from './search'

describe('Search a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(html`<${Search} aria-label="Site search" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has search role', () => {
    render(html`<${Search} />`, container)
    expect(container.querySelector('[role="search"]')).not.toBeNull()
  })

  it('passes aria-label to input', () => {
    render(html`<${Search} aria-label="Global search" />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input.getAttribute('aria-label')).toBe('Global search')
  })

  it('calls onSearch on Enter', async () => {
    const onSearch = vi.fn()
    render(html`<${Search} onSearch=${onSearch} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    input.value = 'hello'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onSearch).toHaveBeenCalledWith('hello')
  })

  it('clears and calls onSearch on Escape', async () => {
    const onSearch = vi.fn()
    render(html`<${Search} onSearch=${onSearch} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    input.value = 'hello'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(input.value).toBe('')
    expect(onSearch).toHaveBeenLastCalledWith('')
  })
})

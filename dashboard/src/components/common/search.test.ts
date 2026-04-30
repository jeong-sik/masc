import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Search } from './search'

describe('Search', () => {
  it('renders input inside role="search"', () => {
    const container = document.createElement('div')
    render(h(Search, {}), container)
    expect(container.querySelector('[role="search"]')).not.toBeNull()
    expect(container.querySelector('input')).not.toBeNull()
  })

  it('calls onSearch on Enter', () => {
    const onSearch = vi.fn()
    const container = document.createElement('div')
    render(h(Search, { value: 'hello', onSearch }), container)
    const input = container.querySelector('input') as HTMLElement
    input?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    expect(onSearch).toHaveBeenCalledWith('hello')
  })

  it('clears value and calls onSearch with empty on Escape', () => {
    const onSearch = vi.fn()
    const container = document.createElement('div')
    render(h(Search, { value: 'hello', onSearch }), container)
    const input = container.querySelector('input') as HTMLElement
    input?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(onSearch).toHaveBeenCalledWith('')
  })

  it('applies placeholder', () => {
    const container = document.createElement('div')
    render(h(Search, { placeholder: 'Find...' }), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.getAttribute('placeholder')).toBe('Find...')
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Search, { 'aria-label': 'Query' }), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.getAttribute('aria-label')).toBe('Query')
  })

  it('applies default aria-label', () => {
    const container = document.createElement('div')
    render(h(Search, {}), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.getAttribute('aria-label')).toBe('Search')
  })

  it('calls onChange on input', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Search, { onChange }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'abc'
    input?.dispatchEvent(new Event('input'))
    expect(onChange).toHaveBeenCalledWith('abc')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Search, { class: 'wide' }), container)
    const el = container.querySelector('[role="search"]')
    expect(el?.classList.contains('wide')).toBe(true)
  })
})

import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { List, ListItem } from './list'

describe('List', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(List, null, 'Items'), container)
    expect(container.textContent).toContain('Items')
  })

  it('has role="list"', () => {
    const container = document.createElement('div')
    render(h(List, null, 'A'), container)
    expect(container.querySelector('ul')?.getAttribute('role')).toBe('list')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(List, { class: 'my-list' }, 'A'), container)
    expect(container.querySelector('ul')?.classList.contains('my-list')).toBe(true)
  })
})

describe('ListItem', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(ListItem, null, 'Item 1'), container)
    expect(container.textContent).toContain('Item 1')
  })

  it('has role="listitem"', () => {
    const container = document.createElement('div')
    render(h(ListItem, null, 'A'), container)
    expect(container.querySelector('li')?.getAttribute('role')).toBe('listitem')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(ListItem, { class: 'item-active' }, 'A'), container)
    expect(container.querySelector('li')?.classList.contains('item-active')).toBe(true)
  })
})

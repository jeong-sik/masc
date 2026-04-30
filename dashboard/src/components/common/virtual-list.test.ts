import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { VirtualList } from './virtual-list'

const items = Array.from({ length: 50 }, (_, i) => ({ id: `item-${i}`, name: `Name ${i}` }))

describe('VirtualList', () => {
  it('renders all items when below activation threshold', () => {
    const container = document.createElement('div')
    const few = items.slice(0, 5)
    render(
      h(VirtualList, {
        items: few,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    expect(container.querySelector('.virtual-list-spacer')).toBeNull()
    expect(container.textContent).toContain('Name 0')
    expect(container.textContent).toContain('Name 4')
  })

  it('renders virtualization structure when above threshold', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    expect(container.querySelector('.virtual-list-spacer')).not.toBeNull()
    expect(container.querySelector('.virtual-list-viewport')).not.toBeNull()
  })

  it('applies className', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        className: 'my-list',
      }),
      container,
    )
    const el = container.querySelector('.my-list')
    expect(el).not.toBeNull()
  })

  it('renders fixed height items with correct total height', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    const spacer = container.querySelector('.virtual-list-spacer') as HTMLElement
    expect(spacer?.style.height).toBe('2000px')
  })

  it('renders dynamic height path when itemHeight is omitted', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList, {
        items,
        estimatedItemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    expect(container.querySelector('.virtual-list-spacer')).not.toBeNull()
    expect(container.querySelector('.virtual-list-viewport')).not.toBeNull()
  })

  it('passes correct index to renderItem', () => {
    const container = document.createElement('div')
    const few = [{ id: 'a' }, { id: 'b' }]
    const renderItem = vi.fn((item: { id: string }, index: number) => h('span', { key: item.id }, `${index}`))
    render(
      h(VirtualList, {
        items: few,
        renderItem,
        getKey: (item) => item.id,
      }),
      container,
    )
    expect(renderItem).toHaveBeenCalledWith(expect.objectContaining({ id: 'a' }), 0)
    expect(renderItem).toHaveBeenCalledWith(expect.objectContaining({ id: 'b' }), 1)
  })

  it('handles empty items', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList, {
        items: [],
        renderItem: (item: { id: string }) => h('div', { key: item.id }, item.id),
        getKey: (item: { id: string }) => item.id,
      }),
      container,
    )
    expect(container.textContent).toBe('')
  })

  it('sets data-vl-key in dynamic mode', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList, {
        items,
        estimatedItemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    const child = container.querySelector('[data-vl-key]')
    expect(child).not.toBeNull()
  })
})

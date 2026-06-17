import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { VirtualList } from './virtual-list'

const items = Array.from({ length: 50 }, (_, i) => ({ id: `item-${i}`, name: `Name ${i}` }))
type Item = (typeof items)[number]

describe('VirtualList', () => {
  it('renders all items when below activation threshold', () => {
    const container = document.createElement('div')
    const few = items.slice(0, 5)
    render(
      h(VirtualList<Item>, {
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
      h(VirtualList<Item>, {
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
      h(VirtualList<Item>, {
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
      h(VirtualList<Item>, {
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
      h(VirtualList<Item>, {
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
      h(VirtualList<{ id: string }>, {
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
      h(VirtualList<{ id: string }>, {
        items: [] as { id: string }[],
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
      h(VirtualList<Item>, {
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

  it('applies content-visibility to fallback rows using fixed itemHeight', () => {
    const container = document.createElement('div')
    const few = items.slice(0, 5)
    render(
      h(VirtualList<Item>, {
        items: few,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    const rows = container.querySelectorAll('.virtual-list-fallback-row')
    expect(rows.length).toBe(5)
    for (const row of rows) {
      const style = (row as HTMLElement).style
      expect(style.contentVisibility).toBe('auto')
      expect(style.containIntrinsicSize).toBe('auto 40px')
    }
  })

  it('applies content-visibility to fallback rows using estimatedItemHeight', () => {
    const container = document.createElement('div')
    const few = items.slice(0, 5)
    render(
      h(VirtualList<Item>, {
        items: few,
        estimatedItemHeight: 48,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )
    const row = container.querySelector('.virtual-list-fallback-row') as HTMLElement
    expect(row.style.contentVisibility).toBe('auto')
    expect(row.style.containIntrinsicSize).toBe('auto 48px')
  })

  it('calls onEndReached once when scrolled near the bottom in fixed-height mode', async () => {
    const container = document.createElement('div')
    const onEndReached = vi.fn()
    render(
      h(VirtualList<Item>, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })
    el.scrollTop = 1700
    el.dispatchEvent(new Event('scroll'))
    await new Promise((resolve) => { setTimeout(resolve, 30) })
    expect(onEndReached).toHaveBeenCalledTimes(1)
  })

  it('calls onEndReached once when scrolled near the bottom in dynamic mode', async () => {
    const container = document.createElement('div')
    const onEndReached = vi.fn()
    render(
      h(VirtualList<Item>, {
        items,
        estimatedItemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })
    el.scrollTop = 1550
    el.dispatchEvent(new Event('scroll'))
    await new Promise((resolve) => { setTimeout(resolve, 30) })
    expect(onEndReached).toHaveBeenCalledTimes(1)
  })

  it('does not call onEndReached when not near the bottom', async () => {
    const container = document.createElement('div')
    const onEndReached = vi.fn()
    render(
      h(VirtualList<Item>, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })
    el.scrollTop = 1000
    el.dispatchEvent(new Event('scroll'))
    await new Promise((resolve) => { setTimeout(resolve, 30) })
    expect(onEndReached).not.toHaveBeenCalled()
  })

  it('resets onEndReached after scrolling away from bottom so it can fire again', async () => {
    const container = document.createElement('div')
    const onEndReached = vi.fn()
    render(
      h(VirtualList<Item>, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })

    el.scrollTop = 1700
    el.dispatchEvent(new Event('scroll'))
    await new Promise((resolve) => { setTimeout(resolve, 30) })
    expect(onEndReached).toHaveBeenCalledTimes(1)

    el.scrollTop = 1000
    el.dispatchEvent(new Event('scroll'))
    await new Promise((resolve) => { setTimeout(resolve, 30) })

    el.scrollTop = 1700
    el.dispatchEvent(new Event('scroll'))
    await new Promise((resolve) => { setTimeout(resolve, 30) })
    expect(onEndReached).toHaveBeenCalledTimes(2)
  })

  it('updates measured heights via ResizeObserver in dynamic mode', async () => {
    const OriginalResizeObserver = global.ResizeObserver
    const callbacks: Array<(entries: ResizeObserverEntry[]) => void> = []
    const observed = new Set<Element>()
    global.ResizeObserver = class MockResizeObserver {
      constructor(callback: ResizeObserverCallback) {
        callbacks.push(callback as (entries: ResizeObserverEntry[]) => void)
      }

      observe(target: Element) {
        observed.add(target)
      }

      disconnect() {
        observed.clear()
      }
    } as unknown as typeof ResizeObserver

    const container = document.createElement('div')
    render(
      h(VirtualList<Item>, {
        items,
        estimatedItemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
      }),
      container,
    )

    await new Promise((resolve) => { setTimeout(resolve, 30) })

    const child = container.querySelector('[data-vl-key]') as HTMLElement
    expect(child).not.toBeNull()
    expect(observed.has(child)).toBe(true)
    expect(callbacks.length).toBeGreaterThan(0)

    const mockEntry = {
      target: child,
      borderBoxSize: [{ blockSize: 88 }],
      contentRect: { height: 88 },
    } as unknown as ResizeObserverEntry
    for (const cb of callbacks) {
      cb([mockEntry])
    }

    const spacer = container.querySelector('.virtual-list-spacer') as HTMLElement
    await vi.waitFor(() => {
      const height = parseInt(spacer.style.height, 10)
      return height > 2000
    }, { timeout: 1000 })

    global.ResizeObserver = OriginalResizeObserver
  })
})

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
        scrollBox: 'self',
      }),
      container,
    )
    expect(container.querySelectorAll('[data-vl-key]')).toHaveLength(5)
    expect(container.textContent).toContain('Name 0')
    expect(container.textContent).toContain('Name 4')
  })

  it('reserves the height of every row when above threshold', () => {
    const container = document.createElement('div')
    render(
      h(VirtualList<Item>, {
        items,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        scrollBox: 'self',
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
        scrollBox: 'self',
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
        scrollBox: 'self',
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
        scrollBox: 'self',
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
        scrollBox: 'self',
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
        scrollBox: 'self',
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
        scrollBox: 'self',
      }),
      container,
    )
    const child = container.querySelector('[data-vl-key]')
    expect(child).not.toBeNull()
  })

  it('applies content-visibility to the rows of a list that draws them all, using fixed itemHeight', () => {
    const container = document.createElement('div')
    const few = items.slice(0, 5)
    render(
      h(VirtualList<Item>, {
        items: few,
        itemHeight: 40,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        scrollBox: 'self',
      }),
      container,
    )
    const rows = container.querySelectorAll('[data-vl-key]')
    expect(rows.length).toBe(5)
    for (const row of rows) {
      const style = (row as HTMLElement).style
      expect(style.contentVisibility).toBe('auto')
      expect(style.containIntrinsicSize).toBe('auto 40px')
    }
  })

  it('applies content-visibility to the rows of a list that draws them all, using estimatedItemHeight', () => {
    const container = document.createElement('div')
    const few = items.slice(0, 5)
    render(
      h(VirtualList<Item>, {
        items: few,
        estimatedItemHeight: 48,
        renderItem: (item) => h('div', { key: item.id }, item.name),
        getKey: (item) => item.id,
        scrollBox: 'self',
      }),
      container,
    )
    const row = container.querySelector('[data-vl-key]') as HTMLElement
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
        scrollBox: 'self',
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })
    el.scrollTop = 1700
    el.dispatchEvent(new Event('scroll'))
    await vi.waitFor(() => { expect(onEndReached).toHaveBeenCalledTimes(1) })
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
        scrollBox: 'self',
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })
    el.scrollTop = 1550
    el.dispatchEvent(new Event('scroll'))
    await vi.waitFor(() => { expect(onEndReached).toHaveBeenCalledTimes(1) })
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
        scrollBox: 'self',
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })
    el.scrollTop = 1000
    el.dispatchEvent(new Event('scroll'))
    // A negative needs a settle rather than a condition wait: there is nothing
    // to wait for. A window that is too short here fails open (the assertion
    // passes because the call had no chance yet), which is a weak test rather
    // than a flaky one, so it is left for a separate change.
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
        scrollBox: 'self',
        onEndReached,
      }),
      container,
    )
    const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
    Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 300, configurable: true })

    el.scrollTop = 1700
    el.dispatchEvent(new Event('scroll'))
    await vi.waitFor(() => { expect(onEndReached).toHaveBeenCalledTimes(1) })

    el.scrollTop = 1000
    el.dispatchEvent(new Event('scroll'))
    // Scrolling away re-arms the latch, and the component exposes nothing that
    // says it processed this event, so this one stays a settle. The assertion
    // after the scroll back waits on the count instead of on a duration, so
    // this is the only window left in the test.
    await new Promise((resolve) => { setTimeout(resolve, 30) })

    el.scrollTop = 1700
    el.dispatchEvent(new Event('scroll'))
    await vi.waitFor(() => { expect(onEndReached).toHaveBeenCalledTimes(2) })
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
        scrollBox: 'self',
      }),
      container,
    )

    await vi.waitFor(() => {
      const rendered = container.querySelector('[data-vl-key]')
      expect(rendered).not.toBeNull()
      expect(observed.has(rendered as HTMLElement)).toBe(true)
      expect(callbacks.length).toBeGreaterThan(0)
    })

    const child = container.querySelector('[data-vl-key]') as HTMLElement

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
  it('observes and remeasures rows that replace the visible keys in the same range', async () => {
    const OriginalResizeObserver = global.ResizeObserver
    const live = new Set<{ callback: ResizeObserverCallback; targets: Set<Element> }>()
    global.ResizeObserver = class MockResizeObserver {
      private readonly entry: { callback: ResizeObserverCallback; targets: Set<Element> }

      constructor(callback: ResizeObserverCallback) {
        this.entry = { callback, targets: new Set() }
        live.add(this.entry)
      }

      observe(target: Element) {
        this.entry.targets.add(target)
      }

      disconnect() {
        this.entry.targets.clear()
        live.delete(this.entry)
      }
    } as unknown as typeof ResizeObserver
    const observedByAnyone = (el: Element) => [...live].some(o => o.targets.has(el))

    try {
      const before = items
      const after = items.map((_, i) => ({ id: `swap-${i}`, name: `Swap ${i}` }))
      const container = document.createElement('div')
      const draw = (list: Item[]) => render(
        h(VirtualList<Item>, {
          items: list,
          estimatedItemHeight: 40,
          renderItem: (item) => h('div', null, item.name),
          // Inline on every render, as work.ts passes it.
          getKey: (item) => item.id,
          scrollBox: 'self',
        }),
        container,
      )

      draw(before)
      await vi.waitFor(() => {
        const row = container.querySelector('[data-vl-key="item-0"]')
        expect(row && observedByAnyone(row)).toBe(true)
      })

      // Same length, same range, every visible key replaced.
      draw(after)
      const swapped = await vi.waitFor(() => {
        const row = container.querySelector('[data-vl-key="swap-0"]')
        expect(row).not.toBeNull()
        expect(observedByAnyone(row as Element)).toBe(true)
        return row as HTMLElement
      })

      const entry = {
        target: swapped,
        borderBoxSize: [{ blockSize: 140 }],
        contentRect: { height: 140 },
      } as unknown as ResizeObserverEntry
      for (const o of [...live]) {
        if (o.targets.has(swapped)) o.callback([entry], o as unknown as ResizeObserver)
      }

      const spacer = container.querySelector('.virtual-list-spacer') as HTMLElement
      await vi.waitFor(() => {
        expect(spacer.style.height).toBe(`${49 * 40 + 140}px`)
      })
    } finally {
      global.ResizeObserver = OriginalResizeObserver
    }
  })

  // What the next frame paints: microtasks have run, timers and animation
  // frames have not. The passive effects wait for those.
  async function beforeNextFrame() {
    await Promise.resolve()
    await Promise.resolve()
  }

  describe.each([
    ['fixed', { itemHeight: 40 }],
    ['measured', { estimatedItemHeight: 40 }],
  ])('with %s row heights, before the next frame', (_mode, heights) => {
    const ROW_PX = 40
    const VIEWPORT_PX = 400
    const many = Array.from({ length: 300 }, (_, i) => ({ id: `item-${i}`, name: `Name ${i}` }))

    function mount() {
      const container = document.createElement('div')
      const draw = (list: Item[]) => render(
        h(VirtualList<Item>, {
          items: list,
          ...heights,
          renderItem: (item) => h('div', null, item.name),
          getKey: (item) => item.id,
          scrollBox: 'self',
        }),
        container,
      )
      draw(many)
      const el = container.querySelector('.virtual-list-spacer')?.parentElement as HTMLElement
      Object.defineProperty(el, 'clientHeight', { value: VIEWPORT_PX, configurable: true })
      /** Where a browser leaves the scroll position of a list this long that sat at its end. */
      const scrollToEndOf = (count: number) => {
        el.scrollTop = count * ROW_PX - VIEWPORT_PX
      }
      return { container, draw, el, scrollToEndOf }
    }

    it('shows the rows at the scroll position after a list scrolled to its end shrinks', async () => {
      const { container, draw, el, scrollToEndOf } = mount()
      scrollToEndOf(many.length)
      el.dispatchEvent(new Event('scroll'))
      await vi.waitFor(() => { expect(container.textContent).toContain('Name 299') })

      const fewer = many.slice(200)
      scrollToEndOf(fewer.length)
      draw(fewer)
      await beforeNextFrame()
      expect(container.textContent).toContain('Name 299')
    })

    it('shows the rows at the scroll position when the list crosses the threshold again', async () => {
      const { container, draw, el, scrollToEndOf } = mount()
      scrollToEndOf(many.length)
      el.dispatchEvent(new Event('scroll'))
      await vi.waitFor(() => { expect(container.textContent).toContain('Name 299') })

      // Below the threshold every row is in the DOM, and the browser has
      // clamped the scroll position to the shorter list.
      draw(many.slice(0, 30))
      await vi.waitFor(() => { expect(container.querySelectorAll('[data-vl-key]')).toHaveLength(30) })
      el.scrollTop = 0

      draw(many.slice(0, 45))
      await beforeNextFrame()
      expect(container.textContent).toContain('Name 0')
    })
  })

  describe('when the item count crosses the threshold', () => {
    const ROW_PX = 40
    const VIEWPORT_PX = 400
    const all = Array.from({ length: 41 }, (_, i) => ({ id: `item-${i}`, name: `Name ${i}` }))

    function mount(count: number) {
      const container = document.createElement('div')
      document.body.appendChild(container)
      const draw = (length: number) => render(
        h(VirtualList<Item>, {
          items: all.slice(0, length),
          estimatedItemHeight: ROW_PX,
          renderItem: (item) => h('button', { type: 'button', 'data-row': item.id }, item.name),
          getKey: (item) => item.id,
          scrollBox: 'self',
        }),
        container,
      )
      draw(count)
      const el = container.firstElementChild as HTMLElement
      Object.defineProperty(el, 'clientHeight', { value: VIEWPORT_PX, configurable: true })
      const button = (id: string) => container.querySelector<HTMLButtonElement>(`[data-row="${id}"]`)
      const unmount = () => {
        render(null, container)
        container.remove()
      }
      return { container, draw, el, button, unmount }
    }

    it('keeps the root, the row and the focus in it from 40 to 41 items and back', async () => {
      const { container, draw, el, button, unmount } = mount(40)
      try {
        const first = button('item-0')
        expect(first).not.toBeNull()
        first?.focus()
        expect(document.activeElement).toBe(first)

        draw(41)
        await beforeNextFrame()
        expect(container.firstElementChild).toBe(el)
        expect(button('item-0')).toBe(first)
        expect(document.activeElement).toBe(first)

        draw(40)
        await beforeNextFrame()
        expect(container.firstElementChild).toBe(el)
        expect(button('item-0')).toBe(first)
        expect(document.activeElement).toBe(first)
        expect(container.querySelectorAll('[data-vl-key]')).toHaveLength(40)
      } finally {
        unmount()
      }
    })

    it('keeps the focused row of a list scrolled to its end when a 41st item arrives', async () => {
      const { draw, el, button, unmount } = mount(40)
      try {
        // The list starts listening in a passive effect, and its scroll
        // handler runs in the animation frame after the event.
        const listen = vi.spyOn(el, 'addEventListener')
        await vi.waitFor(() => {
          expect(listen).toHaveBeenCalledWith('scroll', expect.any(Function), expect.anything())
        })
        el.scrollTop = 40 * ROW_PX - VIEWPORT_PX
        el.dispatchEvent(new Event('scroll'))
        await new Promise((resolve) => { requestAnimationFrame(resolve) })
        await beforeNextFrame()
        const last = button('item-39')
        last?.focus()
        expect(document.activeElement).toBe(last)

        draw(41)
        await beforeNextFrame()
        expect(button('item-39')).toBe(last)
        expect(document.activeElement).toBe(last)
        // 41 items are windowed: the top of the list is off screen and gone.
        expect(button('item-0')).toBeNull()
      } finally {
        unmount()
      }
    })
  })

  it('keeps a measured row height as the browser reported it', async () => {
    const OriginalResizeObserver = global.ResizeObserver
    const live = new Set<{ callback: ResizeObserverCallback; targets: Set<Element> }>()
    global.ResizeObserver = class MockResizeObserver {
      private readonly entry: { callback: ResizeObserverCallback; targets: Set<Element> }

      constructor(callback: ResizeObserverCallback) {
        this.entry = { callback, targets: new Set() }
        live.add(this.entry)
      }

      observe(target: Element) {
        this.entry.targets.add(target)
      }

      disconnect() {
        this.entry.targets.clear()
        live.delete(this.entry)
      }
    } as unknown as typeof ResizeObserver

    try {
      const container = document.createElement('div')
      render(
        h(VirtualList<Item>, {
          items,
          estimatedItemHeight: 41,
          renderItem: (item) => h('div', null, item.name),
          getKey: (item) => item.id,
          scrollBox: 'self',
        }),
        container,
      )
      const row = await vi.waitFor(() => {
        const found = container.querySelector('[data-vl-key="item-0"]')
        expect(found && [...live].some(o => o.targets.has(found))).toBe(true)
        return found as HTMLElement
      })
      const entry = {
        target: row,
        borderBoxSize: [{ blockSize: 40.25 }],
        contentRect: { height: 40.25 },
      } as unknown as ResizeObserverEntry
      for (const o of [...live]) {
        if (o.targets.has(row)) o.callback([entry], o as unknown as ResizeObserver)
      }

      const spacer = container.querySelector('.virtual-list-spacer') as HTMLElement
      await vi.waitFor(() => {
        expect(spacer.style.height).toBe(`${49 * 41 + 40.25}px`)
      })
    } finally {
      global.ResizeObserver = OriginalResizeObserver
    }
  })

  describe('inside a scroll box the caller names', () => {
    const ROW_PX = 40
    const BOX_PX = 400
    const many = Array.from({ length: 300 }, (_, i) => ({ id: `item-${i}`, name: `Name ${i}` }))

    /** A box scrolled by `scrolled` shows the list that far above its own top. */
    function mount() {
      const box = document.createElement('div')
      const container = document.createElement('div')
      box.appendChild(container)
      Object.defineProperty(box, 'clientHeight', { value: BOX_PX, configurable: true })
      let scrolled = 0
      box.getBoundingClientRect = () => new DOMRect(0, 100, 300, BOX_PX)
      const onEndReached = vi.fn()
      render(
        h(VirtualList<Item>, {
          items: many,
          itemHeight: ROW_PX,
          renderItem: (item) => h('div', null, item.name),
          getKey: (item) => item.id,
          scrollBox: box,
          onEndReached,
        }),
        container,
      )
      const root = container.firstElementChild as HTMLElement
      root.getBoundingClientRect = () => new DOMRect(0, 100 - scrolled, 300, many.length * ROW_PX)
      Object.defineProperty(root, 'offsetHeight', { value: many.length * ROW_PX, configurable: true })
      const scrollTo = (top: number) => {
        scrolled = top
        box.dispatchEvent(new Event('scroll'))
      }
      return { container, root, scrollTo, onEndReached }
    }

    it('draws the rows that box shows, not the rows at the top of the list', async () => {
      const { container, scrollTo } = mount()
      scrollTo(200 * ROW_PX)
      await vi.waitFor(() => { expect(container.textContent).toContain('Name 200') })
      expect(container.textContent).toContain('Name 209')
      expect(container.textContent).not.toContain('Name 0')
      expect(container.querySelectorAll('[data-vl-key]').length).toBeLessThan(30)
    })

    it('reports the end when that box reaches the end of the list', async () => {
      const { container, scrollTo, onEndReached } = mount()
      scrollTo(100 * ROW_PX)
      await vi.waitFor(() => { expect(container.textContent).toContain('Name 100') })
      expect(onEndReached).not.toHaveBeenCalled()
      scrollTo(many.length * ROW_PX - BOX_PX)
      await vi.waitFor(() => { expect(onEndReached).toHaveBeenCalledTimes(1) })
    })
  })
})

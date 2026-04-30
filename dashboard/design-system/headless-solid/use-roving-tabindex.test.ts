// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot, createSignal } from 'solid-js'
import type { RovingItemDescriptor } from '../headless-core/roving-tabindex'
import { useRovingTabindex } from './use-roving-tabindex'

let dispose: (() => void) | undefined

beforeEach(() => {
  dispose = undefined
})

afterEach(() => {
  dispose?.()
})

function withRoot<T>(fn: () => T): T {
  return createRoot((d) => {
    dispose = d
    return fn()
  })
}

const fixture: ReadonlyArray<RovingItemDescriptor> = [
  { id: 'a' },
  { id: 'b' },
  { id: 'c' },
]

describe('useRovingTabindex', () => {
  it('initial activeId is first item', () => {
    const { activeId } = withRoot(() =>
      useRovingTabindex({ items: fixture, orientation: 'horizontal' }),
    )
    expect(activeId()).toBe('a')
  })

  it('defaultActiveId honored', () => {
    const { activeId } = withRoot(() =>
      useRovingTabindex({
        items: fixture,
        orientation: 'horizontal',
        defaultActiveId: 'b',
      }),
    )
    expect(activeId()).toBe('b')
  })

  it('next/prev cycle through items', () => {
    const { activeId, next, prev } = withRoot(() =>
      useRovingTabindex({ items: fixture, orientation: 'horizontal' }),
    )
    next()
    expect(activeId()).toBe('b')
    next()
    expect(activeId()).toBe('c')
    prev()
    expect(activeId()).toBe('b')
  })

  it('setActive moves rover', () => {
    const { activeId, setActive } = withRoot(() =>
      useRovingTabindex({ items: fixture, orientation: 'horizontal' }),
    )
    setActive('c')
    expect(activeId()).toBe('c')
  })

  it('first/last jump endpoints', () => {
    const { activeId, last, first } = withRoot(() =>
      useRovingTabindex({ items: fixture, orientation: 'horizontal' }),
    )
    last()
    expect(activeId()).toBe('c')
    first()
    expect(activeId()).toBe('a')
  })

  it('reactive items accessor — controller resyncs', () => {
    const [items, setItems] = createSignal<ReadonlyArray<RovingItemDescriptor>>(fixture)
    const { activeId, items: itemsOut } = withRoot(() =>
      useRovingTabindex({ items, orientation: 'horizontal' }),
    )
    expect(itemsOut().length).toBe(3)
    setItems([{ id: 'x' }, { id: 'y' }])
    expect(itemsOut().length).toBe(2)
    // Active id may shift to first valid id after items shrink.
    expect(['x', 'y', null]).toContain(activeId())
  })

  it('getContainerProps + getItemProps return ARIA-correct shapes', () => {
    const { getContainerProps, getItemProps } = withRoot(() =>
      useRovingTabindex({ items: fixture, orientation: 'horizontal' }),
    )
    const c = getContainerProps()
    expect(typeof c.onKeyDown).toBe('function')
    const a = getItemProps('a')
    expect(a.tabIndex).toBe(0)
    const b = getItemProps('b')
    expect(b.tabIndex).toBe(-1)
  })

  it('onActiveChange fires when rover moves', () => {
    let lastId: string | null = '?'
    const { next } = withRoot(() =>
      useRovingTabindex({
        items: fixture,
        orientation: 'horizontal',
        onActiveChange: (id) => { lastId = id },
      }),
    )
    next()
    expect(lastId).toBe('b')
  })
})

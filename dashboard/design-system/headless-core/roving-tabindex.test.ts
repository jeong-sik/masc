// Pure TS unit tests for RovingTabindex. No DOM, no Preact runtime.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  createRovingTabindex,
  type RovingItemDescriptor,
  type RovingKeyEvent,
} from './roving-tabindex'

function makeKey(key: string, opts?: Partial<RovingKeyEvent>): RovingKeyEvent {
  let prevented = false
  return {
    key,
    shiftKey: opts?.shiftKey,
    metaKey: opts?.metaKey,
    ctrlKey: opts?.ctrlKey,
    altKey: opts?.altKey,
    preventDefault() {
      prevented = true
    },
    // expose for assertion (not part of RovingKeyEvent interface, but
    // tests can read off the returned object)
    get _prevented() {
      return prevented
    },
  } as RovingKeyEvent & { readonly _prevented: boolean }
}

const ITEMS_5: ReadonlyArray<RovingItemDescriptor> = [
  { id: 'a', text: 'apple' },
  { id: 'b', text: 'banana' },
  { id: 'c', text: 'cherry' },
  { id: 'd', text: 'date' },
  { id: 'e', text: 'elderberry' },
]

describe('createRovingTabindex — single-direction movement', () => {
  it('horizontal: ArrowRight moves next, ArrowLeft moves prev; off-axis no-op', () => {
    const c = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    expect(c.activeId).toBe('a')
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(c.activeId).toBe('b')
    c.handleKeyDown(makeKey('ArrowLeft'))
    expect(c.activeId).toBe('a')
    // Off-axis should not move.
    c.handleKeyDown(makeKey('ArrowDown'))
    expect(c.activeId).toBe('a')
  })

  it('vertical: ArrowDown/ArrowUp move; off-axis no-op', () => {
    const c = createRovingTabindex({ orientation: 'vertical', items: ITEMS_5 })
    c.handleKeyDown(makeKey('ArrowDown'))
    expect(c.activeId).toBe('b')
    c.handleKeyDown(makeKey('ArrowUp'))
    expect(c.activeId).toBe('a')
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(c.activeId).toBe('a')
  })

  it('both: all four arrow keys advance the rover', () => {
    const c = createRovingTabindex({ orientation: 'both', items: ITEMS_5 })
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(c.activeId).toBe('b')
    c.handleKeyDown(makeKey('ArrowDown'))
    expect(c.activeId).toBe('c')
    c.handleKeyDown(makeKey('ArrowUp'))
    expect(c.activeId).toBe('b')
    c.handleKeyDown(makeKey('ArrowLeft'))
    expect(c.activeId).toBe('a')
  })
})

describe('createRovingTabindex — boundary behavior', () => {
  it('loop: true wraps last → first on next, first → last on prev', () => {
    const c = createRovingTabindex({
      orientation: 'horizontal',
      items: ITEMS_5,
      loop: true,
    })
    c.last()
    expect(c.activeId).toBe('e')
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(c.activeId).toBe('a')
    c.handleKeyDown(makeKey('ArrowLeft'))
    expect(c.activeId).toBe('e')
  })

  it('loop: false clamps at the boundaries', () => {
    const c = createRovingTabindex({
      orientation: 'horizontal',
      items: ITEMS_5,
      loop: false,
    })
    c.last()
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(c.activeId).toBe('e')
    c.first()
    c.handleKeyDown(makeKey('ArrowLeft'))
    expect(c.activeId).toBe('a')
  })
})

describe('createRovingTabindex — Home / End', () => {
  it('Home selects first enabled, End selects last enabled', () => {
    const c = createRovingTabindex({ orientation: 'vertical', items: ITEMS_5 })
    c.handleKeyDown(makeKey('ArrowDown'))
    c.handleKeyDown(makeKey('ArrowDown'))
    expect(c.activeId).toBe('c')
    c.handleKeyDown(makeKey('End'))
    expect(c.activeId).toBe('e')
    c.handleKeyDown(makeKey('Home'))
    expect(c.activeId).toBe('a')
  })

  it('Home / End skip disabled at the edges', () => {
    const items: ReadonlyArray<RovingItemDescriptor> = [
      { id: 'a', disabled: true },
      { id: 'b', text: 'second' },
      { id: 'c', text: 'third' },
      { id: 'd', text: 'fourth' },
      { id: 'e', disabled: true },
    ]
    const c = createRovingTabindex({ orientation: 'horizontal', items })
    expect(c.activeId).toBe('b') // first enabled, not 'a'
    c.handleKeyDown(makeKey('End'))
    expect(c.activeId).toBe('d') // last enabled, not 'e'
    c.handleKeyDown(makeKey('Home'))
    expect(c.activeId).toBe('b')
  })
})

describe('createRovingTabindex — disabled-skip mid-list', () => {
  it('next/prev skip a single disabled item', () => {
    const items: ReadonlyArray<RovingItemDescriptor> = [
      { id: 'a', text: 'a' },
      { id: 'b', disabled: true },
      { id: 'c', text: 'c' },
    ]
    const c = createRovingTabindex({ orientation: 'horizontal', items })
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(c.activeId).toBe('c')
    c.handleKeyDown(makeKey('ArrowLeft'))
    expect(c.activeId).toBe('a')
  })
})

describe('createRovingTabindex — typeahead', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('printable char focuses next item whose text starts with that char', () => {
    const c = createRovingTabindex({ orientation: 'vertical', items: ITEMS_5 })
    c.handleKeyDown(makeKey('c'))
    expect(c.activeId).toBe('c') // cherry
  })

  it('typeahead is case-insensitive', () => {
    const c = createRovingTabindex({ orientation: 'vertical', items: ITEMS_5 })
    c.handleKeyDown(makeKey('B'))
    expect(c.activeId).toBe('b')
  })

  it('multi-char typeahead buffers within reset window', () => {
    const items: ReadonlyArray<RovingItemDescriptor> = [
      { id: 'aa', text: 'aaron' },
      { id: 'ab', text: 'abel' },
      { id: 'ac', text: 'acorn' },
    ]
    const c = createRovingTabindex({ orientation: 'vertical', items })
    c.handleKeyDown(makeKey('a'))
    expect(c.activeId).toBe('ab') // first non-active match for "a" wraps from current
    c.handleKeyDown(makeKey('c'))
    // Buffer now "ac"; matches "acorn"
    expect(c.activeId).toBe('ac')
  })

  it('typeahead resets after the idle window', () => {
    const c = createRovingTabindex({
      orientation: 'vertical',
      items: ITEMS_5,
      typeaheadResetMs: 100,
    })
    c.handleKeyDown(makeKey('b'))
    expect(c.activeId).toBe('b')
    vi.advanceTimersByTime(150)
    // After reset, single 'c' should jump to cherry, not "bc" prefix.
    c.handleKeyDown(makeKey('c'))
    expect(c.activeId).toBe('c')
  })
})

describe('createRovingTabindex — defaultActiveId', () => {
  it('uses defaultActiveId when present and enabled', () => {
    const c = createRovingTabindex({
      orientation: 'horizontal',
      items: ITEMS_5,
      defaultActiveId: 'c',
    })
    expect(c.activeId).toBe('c')
  })

  it('falls back to first enabled when defaultActiveId is missing', () => {
    const c = createRovingTabindex({
      orientation: 'horizontal',
      items: ITEMS_5,
      defaultActiveId: 'nope',
    })
    expect(c.activeId).toBe('a')
  })

  it('falls back to first enabled when defaultActiveId points to disabled', () => {
    const items: ReadonlyArray<RovingItemDescriptor> = [
      { id: 'a' },
      { id: 'b', disabled: true },
      { id: 'c' },
    ]
    const c = createRovingTabindex({
      orientation: 'horizontal',
      items,
      defaultActiveId: 'b',
    })
    expect(c.activeId).toBe('a')
  })
})

describe('createRovingTabindex — setItems re-anchor', () => {
  it('keeps active id when still present', () => {
    const c = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    c.last()
    expect(c.activeId).toBe('e')
    c.setItems([...ITEMS_5, { id: 'f' }])
    expect(c.activeId).toBe('e')
  })

  it('re-anchors when active id is removed', () => {
    const c = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    c.setActive('c')
    c.setItems([
      { id: 'a' },
      { id: 'b' },
      // c removed
      { id: 'd' },
      { id: 'e' },
    ])
    expect(c.activeId).not.toBe('c')
    // Falls back to a still-enabled item.
    expect(['a', 'b', 'd', 'e']).toContain(c.activeId)
  })
})

describe('createRovingTabindex — subscribe / onActiveChange', () => {
  it('subscribe listener fires on active change', () => {
    const fired: Array<string | null> = []
    const c = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    const dispose = c.subscribe((id) => fired.push(id))
    c.handleKeyDown(makeKey('ArrowRight'))
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(fired).toEqual(['b', 'c'])
    dispose()
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(fired).toEqual(['b', 'c'])
  })

  it('onActiveChange callback fires alongside subscribers (activateOnFocus)', () => {
    const calls: Array<string | null> = []
    const c = createRovingTabindex({
      orientation: 'horizontal',
      items: ITEMS_5,
      activateOnFocus: true,
      onActiveChange: (id) => calls.push(id),
    })
    c.handleKeyDown(makeKey('ArrowRight'))
    expect(calls).toEqual(['b'])
  })
})

describe('createRovingTabindex — getContainerProps / getItemProps', () => {
  it('container exposes aria-orientation for horizontal/vertical, omitted for both', () => {
    const h = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    expect(h.getContainerProps()['aria-orientation']).toBe('horizontal')
    const v = createRovingTabindex({ orientation: 'vertical', items: ITEMS_5 })
    expect(v.getContainerProps()['aria-orientation']).toBe('vertical')
    const both = createRovingTabindex({ orientation: 'both', items: ITEMS_5 })
    expect(both.getContainerProps()['aria-orientation']).toBeUndefined()
  })

  it('itemProps marks active with tabIndex=0 + data-active="", others tabIndex=-1', () => {
    const c = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    const aProps = c.getItemProps('a')
    const bProps = c.getItemProps('b')
    expect(aProps.tabIndex).toBe(0)
    expect(aProps['data-active']).toBe('')
    expect(bProps.tabIndex).toBe(-1)
    expect(bProps['data-active']).toBeUndefined()
  })

  it('itemProps adds aria-disabled for disabled items', () => {
    const items: ReadonlyArray<RovingItemDescriptor> = [
      { id: 'a' },
      { id: 'b', disabled: true },
    ]
    const c = createRovingTabindex({ orientation: 'horizontal', items })
    expect(c.getItemProps('b')['aria-disabled']).toBe(true)
    expect(c.getItemProps('a')['aria-disabled']).toBeUndefined()
  })

  it('handleKeyDown ignores keys with Meta/Ctrl/Alt modifiers (reserved for shortcuts)', () => {
    const c = createRovingTabindex({ orientation: 'horizontal', items: ITEMS_5 })
    c.handleKeyDown(makeKey('ArrowRight', { metaKey: true }))
    expect(c.activeId).toBe('a')
    c.handleKeyDown(makeKey('ArrowRight', { ctrlKey: true }))
    expect(c.activeId).toBe('a')
    c.handleKeyDown(makeKey('ArrowRight', { altKey: true }))
    expect(c.activeId).toBe('a')
  })
})

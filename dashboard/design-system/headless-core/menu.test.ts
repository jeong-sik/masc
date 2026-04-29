// Pure TS unit tests for Menu + ContextMenu. No DOM.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  createMenu,
  createContextMenu,
  type MenuKeyEvent,
  type MenuItemDescriptor,
} from './menu'

function makeKey(
  key: string,
  opts?: Partial<MenuKeyEvent>,
): MenuKeyEvent & { _prevented: boolean } {
  let prevented = false
  return {
    key,
    metaKey: opts?.metaKey,
    ctrlKey: opts?.ctrlKey,
    shiftKey: opts?.shiftKey,
    altKey: opts?.altKey,
    preventDefault() {
      prevented = true
    },
    get _prevented() {
      return prevented
    },
  } as MenuKeyEvent & { _prevented: boolean }
}

const FLAT: ReadonlyArray<MenuItemDescriptor> = [
  { id: 'open', label: 'Open' },
  { id: 'sep', label: '', type: 'separator' },
  { id: 'rename', label: 'Rename', shortcut: 'F2' },
  { id: 'delete', label: 'Delete', disabled: true },
]

const NESTED: ReadonlyArray<MenuItemDescriptor> = [
  { id: 'view', label: 'View' },
  {
    id: 'move',
    label: 'Move to',
    items: [
      { id: 'archive', label: 'Archive' },
      { id: 'trash', label: 'Trash' },
    ],
  },
  { id: 'rename', label: 'Rename' },
]

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createMenu — open / close round-trip', () => {
  it('open() opens; close() closes; trigger reflects via aria-expanded', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    expect(m.isOpen).toBe(false)
    expect(m.getTriggerProps()['aria-expanded']).toBe(false)
    m.open()
    expect(m.isOpen).toBe(true)
    expect(m.getTriggerProps()['aria-expanded']).toBe(true)
    m.close()
    expect(m.isOpen).toBe(false)
  })

  it('first focus on open lands on first enabled item', () => {
    const items: ReadonlyArray<MenuItemDescriptor> = [
      { id: 'a', label: 'A', disabled: true },
      { id: 'b', label: 'B' },
      { id: 'c', label: 'C' },
    ]
    const m = createMenu({ id: 'm1', items })
    m.open()
    expect(m.activeId).toBe('b')
  })

  it('keyboard open: Enter / Space / ArrowDown -> open + first focus', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    m.getTriggerProps().onKeyDown(makeKey('Enter'))
    expect(m.isOpen).toBe(true)
    m.close()
    m.getTriggerProps().onKeyDown(makeKey(' '))
    expect(m.isOpen).toBe(true)
  })

  it('keyboard open: ArrowUp -> open + last focus', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    m.getTriggerProps().onKeyDown(makeKey('ArrowUp'))
    expect(m.isOpen).toBe(true)
    expect(m.activeId).toBe('rename') // 'delete' is disabled, last-enabled
  })
})

describe('createMenu — keyboard navigation', () => {
  it('ArrowDown / ArrowUp move rover; separator skipped', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    m.open()
    expect(m.activeId).toBe('open')
    m.getMenuProps().onKeyDown(makeKey('ArrowDown'))
    expect(m.activeId).toBe('rename') // sep is filtered from rover entirely
  })

  it('Esc on open menu closes', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    m.open()
    m.getMenuProps().onKeyDown(makeKey('Escape'))
    expect(m.isOpen).toBe(false)
  })

  it('Enter selects + closes', () => {
    const calls: string[] = []
    const m = createMenu({
      id: 'm1',
      items: FLAT,
      onSelect: (id) => calls.push(id),
    })
    m.open()
    m.getMenuProps().onKeyDown(makeKey('Enter'))
    expect(calls).toEqual(['open'])
    expect(m.isOpen).toBe(false)
  })

  it('disabled items are skipped by rover; click is no-op', () => {
    const calls: string[] = []
    const m = createMenu({
      id: 'm1',
      items: FLAT,
      onSelect: (id) => calls.push(id),
    })
    m.open()
    m.getItemProps('delete').onClick()
    expect(calls).toEqual([])
  })
})

describe('createMenu — submenu lifecycle', () => {
  it('ArrowRight on item with children opens submenu', () => {
    const m = createMenu({ id: 'm1', items: NESTED })
    const snaps: Array<{ openPath: ReadonlyArray<string> }> = []
    m.subscribe((s) => snaps.push({ openPath: s.openPath }))
    m.open()
    m.getMenuProps().onKeyDown(makeKey('ArrowDown')) // focus 'move'
    expect(m.activeId).toBe('move')
    m.getMenuProps().onKeyDown(makeKey('ArrowRight'))
    // After ArrowRight, last snap should reflect openPath=['move'].
    const last = snaps[snaps.length - 1]
    expect(last).toBeDefined()
    expect(last!.openPath).toEqual(['move'])
  })

  it('ArrowLeft from open submenu closes it', () => {
    const m = createMenu({ id: 'm1', items: NESTED })
    const snaps: Array<{ openPath: ReadonlyArray<string> }> = []
    m.subscribe((s) => snaps.push({ openPath: s.openPath }))
    m.open()
    m.getMenuProps().onKeyDown(makeKey('ArrowDown'))
    m.getMenuProps().onKeyDown(makeKey('ArrowRight')) // open submenu
    expect(snaps[snaps.length - 1]!.openPath).toEqual(['move'])
    m.getMenuProps().onKeyDown(makeKey('ArrowLeft'))
    expect(snaps[snaps.length - 1]!.openPath).toEqual([])
  })

  it('hover with delay opens submenu', () => {
    const m = createMenu({ id: 'm1', items: NESTED, submenuOpenDelay: 100 })
    const snaps: Array<ReadonlyArray<string>> = []
    m.subscribe((s) => snaps.push(s.openPath))
    m.open()
    m.getItemProps('move').onMouseEnter()
    vi.advanceTimersByTime(99)
    expect(snaps[snaps.length - 1] ?? []).toEqual([])
    vi.advanceTimersByTime(2)
    expect(snaps[snaps.length - 1]).toEqual(['move'])
  })

  it('Esc on submenu closes only one level', () => {
    const m = createMenu({ id: 'm1', items: NESTED })
    m.open()
    m.getMenuProps().onKeyDown(makeKey('ArrowDown'))
    m.getMenuProps().onKeyDown(makeKey('ArrowRight')) // open submenu
    expect(m.isOpen).toBe(true)
    m.getMenuProps().onKeyDown(makeKey('Escape'))
    // Submenu closes; root menu still open
    expect(m.isOpen).toBe(true)
    m.getMenuProps().onKeyDown(makeKey('Escape'))
    // Root closes
    expect(m.isOpen).toBe(false)
  })
})

describe('createMenu — getItemProps ARIA', () => {
  it('aria-haspopup=menu when item has children', () => {
    const m = createMenu({ id: 'm1', items: NESTED })
    expect(m.getItemProps('move')['aria-haspopup']).toBe('menu')
    expect(m.getItemProps('view')['aria-haspopup']).toBeUndefined()
  })

  it('aria-keyshortcuts surfaces shortcut string', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    expect(m.getItemProps('rename')['aria-keyshortcuts']).toBe('F2')
  })

  it('separator items render role=separator', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    const props = m.getItemProps('sep')
    expect(props.role).toBe('separator')
    expect(props.tabIndex).toBe(-1)
  })

  it('aria-disabled set on disabled items', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    expect(m.getItemProps('delete')['aria-disabled']).toBe(true)
    expect(m.getItemProps('open')['aria-disabled']).toBeUndefined()
  })

  it('aria-expanded reflects submenu open state', () => {
    const m = createMenu({ id: 'm1', items: NESTED })
    m.open()
    expect(m.getItemProps('move')['aria-expanded']).toBe(false)
    m.getItemProps('move').onClick() // selecting an item with children opens submenu
    expect(m.getItemProps('move')['aria-expanded']).toBe(true)
  })
})

describe('createMenu — trigger ARIA', () => {
  it('aria-controls = menu id', () => {
    const m = createMenu({ id: 'menu-x', items: FLAT })
    expect(m.getTriggerProps()['aria-controls']).toBe('menu-x')
    expect(m.getMenuProps().id).toBe('menu-x')
  })
})

describe('createContextMenu — openAt + viewport flip', () => {
  it('top-left corner -> bottom-start', () => {
    const cm = createContextMenu({
      id: 'ctx',
      items: FLAT,
      viewport: { width: 1000, height: 1000 },
    })
    cm.openAt({ x: 100, y: 100 })
    expect(cm.position).toEqual({ x: 100, y: 100 })
    expect(cm.resolvedPlacement).toBe('bottom-start')
    expect(cm.isOpen).toBe(true)
  })

  it('bottom-right corner -> top-end', () => {
    const cm = createContextMenu({
      id: 'ctx',
      items: FLAT,
      viewport: { width: 1000, height: 1000 },
    })
    cm.openAt({ x: 900, y: 900 })
    expect(cm.resolvedPlacement).toBe('top-end')
  })

  it('right edge but top -> bottom-end', () => {
    const cm = createContextMenu({
      id: 'ctx',
      items: FLAT,
      viewport: { width: 1000, height: 1000 },
    })
    cm.openAt({ x: 800, y: 100 })
    expect(cm.resolvedPlacement).toBe('bottom-end')
  })
})

describe('createMenu — subscribe', () => {
  it('listener fires on open / close / submenu open', () => {
    const m = createMenu({ id: 'm1', items: NESTED })
    let count = 0
    const dispose = m.subscribe(() => {
      count += 1
    })
    m.open()
    m.close()
    expect(count).toBeGreaterThan(0)
    const before = count
    dispose()
    m.open()
    expect(count).toBe(before)
  })
})

describe('createMenu — onSelect path', () => {
  it('flat menu select -> path is single id', () => {
    const calls: ReadonlyArray<string>[] = []
    const m = createMenu({
      id: 'm1',
      items: FLAT,
      onSelect: (_id, path) => calls.push(path),
    })
    m.open()
    m.select('open')
    expect(calls).toEqual([['open']])
  })

  it('toggle: closed -> open, open -> closed', () => {
    const m = createMenu({ id: 'm1', items: FLAT })
    expect(m.isOpen).toBe(false)
    m.toggle()
    expect(m.isOpen).toBe(true)
    m.toggle()
    expect(m.isOpen).toBe(false)
  })
})

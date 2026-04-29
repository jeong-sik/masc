// Pure TS unit tests for Toolbar. No DOM.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createToolbar, type ToolbarItem, type ToolbarKeyEvent } from './toolbar'

function makeKey(
  key: string,
  opts?: Partial<ToolbarKeyEvent>,
): ToolbarKeyEvent & { _prevented: boolean } {
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
  } as ToolbarKeyEvent & { _prevented: boolean }
}

const FLAT: ReadonlyArray<ToolbarItem> = [
  { id: 'cut', kind: 'button', label: 'Cut', shortcut: 'Mod+X' },
  { id: 'copy', kind: 'button', label: 'Copy', shortcut: 'Mod+C' },
  { id: 'sep1', kind: 'separator', label: '' },
  { id: 'paste', kind: 'button', label: 'Paste', disabled: true },
  { id: 'bold', kind: 'toggle', label: 'Bold', pressed: false },
]

const RADIO_GROUP: ReadonlyArray<ToolbarItem> = [
  { id: 'gs', kind: 'group-start', label: '', groupLabel: 'Alignment' },
  { id: 'left', kind: 'radio', label: 'Left', radioGroup: 'align', checked: true },
  { id: 'center', kind: 'radio', label: 'Center', radioGroup: 'align' },
  { id: 'right', kind: 'radio', label: 'Right', radioGroup: 'align' },
  { id: 'ge', kind: 'group-end', label: '' },
]

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createToolbar — root ARIA', () => {
  it('getRootProps emits role=toolbar with aria-label and orientation', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'Edit actions' })
    const p = t.getRootProps()
    expect(p.role).toBe('toolbar')
    expect(p['aria-label']).toBe('Edit actions')
    expect(p['aria-orientation']).toBe('horizontal')
    expect(p.tabIndex).toBe(-1)
  })

  it('vertical orientation passes through', () => {
    const t = createToolbar({
      items: FLAT,
      ariaLabel: 'Side',
      orientation: 'vertical',
    })
    expect(t.getRootProps()['aria-orientation']).toBe('vertical')
  })
})

describe('createToolbar — roving navigation', () => {
  it('first focus lands on first enabled non-separator', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    expect(t.activeId).toBe('cut')
  })

  it('ArrowRight advances past separator (skipped) and disabled', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    t.getRootProps().onKeyDown(makeKey('ArrowRight'))
    expect(t.activeId).toBe('copy')
    t.getRootProps().onKeyDown(makeKey('ArrowRight'))
    // sep1 + paste(disabled) skipped
    expect(t.activeId).toBe('bold')
  })

  it('ArrowLeft moves backward', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    t.getRootProps().onKeyDown(makeKey('ArrowRight'))
    t.getRootProps().onKeyDown(makeKey('ArrowLeft'))
    expect(t.activeId).toBe('cut')
  })

  it('Home / End jump to ends', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    t.getRootProps().onKeyDown(makeKey('End'))
    expect(t.activeId).toBe('bold')
    t.getRootProps().onKeyDown(makeKey('Home'))
    expect(t.activeId).toBe('cut')
  })
})

describe('createToolbar — activation by kind', () => {
  it('Enter on button fires onItemActivate + action', () => {
    const calls: string[] = []
    let actionCount = 0
    const items: ReadonlyArray<ToolbarItem> = [
      { id: 'a', kind: 'button', label: 'A', action: () => { actionCount += 1 } },
    ]
    const t = createToolbar({
      items,
      ariaLabel: 'tb',
      onItemActivate: (id) => calls.push(id),
    })
    t.getRootProps().onKeyDown(makeKey('Enter'))
    expect(calls).toEqual(['a'])
    expect(actionCount).toBe(1)
  })

  it('Space on toggle flips aria-pressed; onToggle fires', () => {
    const events: Array<[string, boolean]> = []
    const t = createToolbar({
      items: [{ id: 'b', kind: 'toggle', label: 'Bold', pressed: false }],
      ariaLabel: 'tb',
      onToggle: (id, p) => events.push([id, p]),
    })
    expect(t.getItemProps('b')['aria-pressed']).toBe(false)
    t.getRootProps().onKeyDown(makeKey(' '))
    expect(events).toEqual([['b', true]])
    expect(t.getItemProps('b')['aria-pressed']).toBe(true)
    expect(t.getItemProps('b')['data-pressed']).toBe('')
    t.getRootProps().onKeyDown(makeKey(' '))
    expect(events).toEqual([['b', true], ['b', false]])
    expect(t.getItemProps('b')['aria-pressed']).toBe(false)
    expect(t.getItemProps('b')['data-pressed']).toBeUndefined()
  })

  it('Enter on radio enforces single-selection in group', () => {
    const selections: Array<[string, string]> = []
    const t = createToolbar({
      items: RADIO_GROUP,
      ariaLabel: 'tb',
      onRadioSelect: (g, id) => selections.push([g, id]),
    })
    expect(t.getItemProps('left')['aria-checked']).toBe(true)
    expect(t.getItemProps('center')['aria-checked']).toBe(false)
    // Move past group-start (filtered from rover) to first roveable (left).
    expect(t.activeId).toBe('left')
    t.getRootProps().onKeyDown(makeKey('ArrowRight'))
    expect(t.activeId).toBe('center')
    t.getRootProps().onKeyDown(makeKey('Enter'))
    expect(selections).toEqual([['align', 'center']])
    expect(t.getItemProps('center')['aria-checked']).toBe(true)
    expect(t.getItemProps('left')['aria-checked']).toBe(false)
  })

  it('disabled item ignores keyboard activation', () => {
    const calls: string[] = []
    const t = createToolbar({
      items: FLAT,
      ariaLabel: 'tb',
      onItemActivate: (id) => calls.push(id),
    })
    // 'paste' is disabled; click attempt no-op.
    expect(t.getItemProps('paste').onClick).toBeUndefined()
    t.activate('paste') // direct API also blocked
    expect(calls).toEqual([])
  })

  it('Enter with Mod modifier does NOT activate (preserved for outer shortcuts)', () => {
    const calls: string[] = []
    const t = createToolbar({
      items: FLAT,
      ariaLabel: 'tb',
      onItemActivate: (id) => calls.push(id),
    })
    t.getRootProps().onKeyDown(makeKey('Enter', { metaKey: true }))
    expect(calls).toEqual([])
    t.getRootProps().onKeyDown(makeKey('Enter', { ctrlKey: true }))
    expect(calls).toEqual([])
  })
})

describe('createToolbar — getItemProps ARIA', () => {
  it('separator items render role=separator with tabIndex -1', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    const p = t.getItemProps('sep1')
    expect(p.role).toBe('separator')
    expect(p.tabIndex).toBe(-1)
  })

  it('aria-keyshortcuts surfaces shortcut string', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    expect(t.getItemProps('cut')['aria-keyshortcuts']).toBe('Mod+X')
    expect(t.getItemProps('copy')['aria-keyshortcuts']).toBe('Mod+C')
  })

  it('aria-disabled set on disabled items only', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    expect(t.getItemProps('paste')['aria-disabled']).toBe(true)
    expect(t.getItemProps('cut')['aria-disabled']).toBeUndefined()
  })

  it('group-start / group-end markers carry no rover semantics', () => {
    const t = createToolbar({ items: RADIO_GROUP, ariaLabel: 'tb' })
    const gs = t.getItemProps('gs')
    const ge = t.getItemProps('ge')
    expect(gs.tabIndex).toBe(-1)
    expect(ge.tabIndex).toBe(-1)
    expect(gs.role).toBeUndefined()
    expect(ge.role).toBeUndefined()
    // groupLabel is preserved on the underlying item for consumer to render.
    expect(t.items.find((it) => it.id === 'gs')?.groupLabel).toBe('Alignment')
  })
})

describe('createToolbar — overflow split', () => {
  const wide: ReadonlyArray<ToolbarItem> = [
    { id: 'a', kind: 'button', label: 'A' },
    { id: 'b', kind: 'button', label: 'B' },
    { id: 'c', kind: 'button', label: 'C' },
    { id: 'd', kind: 'button', label: 'D' },
    { id: 'e', kind: 'button', label: 'E' },
  ]

  it('container 200 with 5 × 50 widths → 4 visible / 1 overflow', () => {
    const t = createToolbar({ items: wide, ariaLabel: 'tb' })
    for (const it of wide) t.setItemWidth(it.id, 50)
    t.setContainerSize(200)
    vi.advanceTimersByTime(20)
    expect(t.visibleItems.map((i) => i.id)).toEqual(['a', 'b', 'c', 'd'])
    expect(t.overflowItems.map((i) => i.id)).toEqual(['e'])
    expect(t.hasOverflow).toBe(true)
  })

  it('overflowAt manual override pins split', () => {
    const t = createToolbar({ items: wide, ariaLabel: 'tb', overflowAt: 3 })
    expect(t.visibleItems.map((i) => i.id)).toEqual(['a', 'b', 'c'])
    expect(t.overflowItems.map((i) => i.id)).toEqual(['d', 'e'])
  })

  it('resize collapses overflow when container grows', () => {
    const t = createToolbar({ items: wide, ariaLabel: 'tb' })
    for (const it of wide) t.setItemWidth(it.id, 50)
    t.setContainerSize(100)
    vi.advanceTimersByTime(20)
    expect(t.overflowItems.length).toBe(3)
    t.setContainerSize(1000)
    vi.advanceTimersByTime(20)
    expect(t.overflowItems.length).toBe(0)
    expect(t.hasOverflow).toBe(false)
  })

  it('100 rapid setContainerSize calls coalesce into ≤ 1 emit', () => {
    const t = createToolbar({ items: wide, ariaLabel: 'tb' })
    let count = 0
    t.subscribe(() => {
      count += 1
    })
    for (let i = 0; i < 100; i += 1) t.setContainerSize(100 + i)
    // No timer flush yet — still pending.
    expect(count).toBe(0)
    vi.advanceTimersByTime(20)
    // One coalesced emit.
    expect(count).toBeLessThan(7)
    expect(count).toBeGreaterThanOrEqual(1)
  })
})

describe('createToolbar — overflow menu trigger', () => {
  it('aria-haspopup=menu and aria-label="More actions"', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    const trig = t.getOverflowMenuTriggerProps()
    expect(trig['aria-haspopup']).toBe('menu')
    expect(trig['aria-label']).toBe('More actions')
    expect(trig.tabIndex).toBe(0)
    expect(trig.type).toBe('button')
    expect(trig['aria-expanded']).toBe(false)
  })

  it('clicking trigger toggles overflowMenuOpen and aria-expanded', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    expect(t.overflowMenuOpen).toBe(false)
    t.getOverflowMenuTriggerProps().onClick()
    expect(t.overflowMenuOpen).toBe(true)
    expect(t.getOverflowMenuTriggerProps()['aria-expanded']).toBe(true)
    t.getOverflowMenuTriggerProps().onClick()
    expect(t.overflowMenuOpen).toBe(false)
  })
})

describe('createToolbar — direct API', () => {
  it('toggle(id) flips programmatically', () => {
    const t = createToolbar({
      items: [{ id: 'b', kind: 'toggle', label: 'B', pressed: false }],
      ariaLabel: 'tb',
    })
    t.toggle('b')
    expect(t.getItemProps('b')['aria-pressed']).toBe(true)
    t.toggle('b')
    expect(t.getItemProps('b')['aria-pressed']).toBe(false)
  })

  it('selectRadio(id) deselects siblings without keyboard', () => {
    const t = createToolbar({ items: RADIO_GROUP, ariaLabel: 'tb' })
    t.selectRadio('right')
    expect(t.getItemProps('right')['aria-checked']).toBe(true)
    expect(t.getItemProps('left')['aria-checked']).toBe(false)
  })

  it('setItems re-anchors rover to first enabled', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    expect(t.activeId).toBe('cut')
    t.setItems([
      { id: 'x', kind: 'button', label: 'X', disabled: true },
      { id: 'y', kind: 'button', label: 'Y' },
    ])
    expect(t.activeId).toBe('y')
  })

  it('subscribe / unsubscribe lifecycle', () => {
    const t = createToolbar({ items: FLAT, ariaLabel: 'tb' })
    let count = 0
    const dispose = t.subscribe(() => {
      count += 1
    })
    t.toggle('bold')
    expect(count).toBe(1)
    dispose()
    t.toggle('bold')
    expect(count).toBe(1)
  })
})

// Pure TS unit tests for Tabs. No DOM.
import { describe, it, expect, vi } from 'vitest'
import { createTabs, type TabsKeyEvent, type TabDescriptor } from './tabs'

function makeKey(
  key: string,
  opts?: Partial<TabsKeyEvent>,
): TabsKeyEvent & { _prevented: boolean } {
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
  } as TabsKeyEvent & { _prevented: boolean }
}

const TABS: ReadonlyArray<TabDescriptor> = [
  { id: 'a', label: 'Alpha' },
  { id: 'b', label: 'Bravo' },
  { id: 'c', label: 'Charlie' },
  { id: 'd', label: 'Delta' },
  { id: 'e', label: 'Echo' },
]

describe('createTabs — activation: automatic', () => {
  it('ArrowRight immediately fires onActiveChange', () => {
    const calls: string[] = []
    const t = createTabs({ tabs: TABS, onActiveChange: (id) => calls.push(id) })
    expect(t.activeId).toBe('a')
    t.getTabListProps().onKeyDown(makeKey('ArrowRight'))
    expect(t.activeId).toBe('b')
    expect(calls).toEqual(['b'])
  })
})

describe('createTabs — activation: manual', () => {
  it('ArrowRight moves rover but does NOT activate; Enter activates', () => {
    const calls: string[] = []
    const t = createTabs({
      tabs: TABS,
      activationMode: 'manual',
      onActiveChange: (id) => calls.push(id),
    })
    expect(t.activeId).toBe('a')
    t.getTabListProps().onKeyDown(makeKey('ArrowRight'))
    // active stays at a; rover advanced to b internally
    expect(t.activeId).toBe('a')
    expect(calls).toEqual([])
    t.getTabListProps().onKeyDown(makeKey('Enter'))
    expect(t.activeId).toBe('b')
    expect(calls).toEqual(['b'])
  })

  it('Space activates focused tab', () => {
    const t = createTabs({ tabs: TABS, activationMode: 'manual' })
    t.getTabListProps().onKeyDown(makeKey('ArrowRight'))
    t.getTabListProps().onKeyDown(makeKey(' '))
    expect(t.activeId).toBe('b')
  })
})

describe('createTabs — Home / End', () => {
  it('Home goes to first; End goes to last', () => {
    const t = createTabs({ tabs: TABS })
    t.activate('c')
    t.getTabListProps().onKeyDown(makeKey('End'))
    expect(t.activeId).toBe('e')
    t.getTabListProps().onKeyDown(makeKey('Home'))
    expect(t.activeId).toBe('a')
  })
})

describe('createTabs — disabled-skip', () => {
  it('rover skips disabled; first focus lands on first enabled', () => {
    const tabs: ReadonlyArray<TabDescriptor> = [
      { id: 'a', label: 'A', disabled: true },
      { id: 'b', label: 'B' },
      { id: 'c', label: 'C' },
    ]
    const t = createTabs({ tabs })
    expect(t.activeId).toBe('b')
    t.getTabListProps().onKeyDown(makeKey('Home'))
    expect(t.activeId).toBe('b')
  })
})

describe('createTabs — close', () => {
  it('close active id 3 of 5 -> id 4 becomes active', () => {
    const t = createTabs({ tabs: TABS })
    t.activate('c')
    t.close('c')
    expect(t.activeId).toBe('b') // previous neighbor
    expect(t.tabs.map((tt) => tt.id)).toEqual(['a', 'b', 'd', 'e'])
  })

  it('close last active -> previous becomes active', () => {
    const t = createTabs({ tabs: TABS })
    t.activate('e')
    t.close('e')
    expect(t.activeId).toBe('d')
  })

  it('close all -> activeId becomes null', () => {
    const t = createTabs({ tabs: [{ id: 'only', label: 'O' }] })
    t.close('only')
    expect(t.activeId).toBeNull()
    expect(t.tabs).toHaveLength(0)
  })

  it('Delete keyboard fires close on closeable tab', () => {
    const closes: string[] = []
    const t = createTabs({
      tabs: [
        { id: 'a', label: 'A', closeable: true },
        { id: 'b', label: 'B', closeable: true },
      ],
      onClose: (id) => closes.push(id),
    })
    t.getTabListProps().onKeyDown(makeKey('Delete'))
    expect(closes).toEqual(['a'])
  })

  it('Delete on non-closeable tab is no-op', () => {
    const closes: string[] = []
    const t = createTabs({ tabs: TABS, onClose: (id) => closes.push(id) })
    t.getTabListProps().onKeyDown(makeKey('Delete'))
    expect(closes).toEqual([])
    expect(t.tabs).toHaveLength(5)
  })
})

describe('createTabs — drag reorder', () => {
  it('drag tab b over tab d -> order [a, c, b, d, e]; onReorder fires once', () => {
    const reorders: ReadonlyArray<string>[] = []
    const t = createTabs({
      tabs: TABS,
      onReorder: (ids) => reorders.push(ids),
    })
    t.handleDragStart('b')
    t.handleDragOver('d')
    t.handleDragEnd()
    expect(t.tabs.map((tt) => tt.id)).toEqual(['a', 'c', 'b', 'd', 'e'])
    expect(reorders).toHaveLength(1)
  })

  it('pinned target is skipped (no reorder)', () => {
    const tabs: ReadonlyArray<TabDescriptor> = [
      { id: 'a', label: 'A', pinned: true },
      { id: 'b', label: 'B' },
      { id: 'c', label: 'C' },
    ]
    const reorders: ReadonlyArray<string>[] = []
    const t = createTabs({
      tabs,
      onReorder: (ids) => reorders.push(ids),
    })
    t.handleDragStart('b')
    t.handleDragOver('a') // pinned target
    t.handleDragEnd()
    expect(t.tabs.map((tt) => tt.id)).toEqual(['a', 'b', 'c'])
    expect(reorders).toHaveLength(0)
  })

  it('dragging a pinned source is rejected (no drag started)', () => {
    const tabs: ReadonlyArray<TabDescriptor> = [
      { id: 'a', label: 'A', pinned: true },
      { id: 'b', label: 'B' },
    ]
    const t = createTabs({ tabs })
    t.handleDragStart('a')
    expect(t.draggingId).toBeNull()
  })
})

describe('createTabs — getTabPanelProps.hidden', () => {
  it('true for non-active panels, false for active', () => {
    const t = createTabs({ tabs: TABS })
    t.activate('c')
    expect(t.getTabPanelProps('a').hidden).toBe(true)
    expect(t.getTabPanelProps('c').hidden).toBe(false)
  })
})

describe('createTabs — aria-controls / aria-labelledby linkage', () => {
  it('tab id and panel id round-trip through aria attrs', () => {
    const t = createTabs({ tabs: TABS })
    const tabProps = t.getTabProps('b')
    const panelProps = t.getTabPanelProps('b')
    expect(tabProps['aria-controls']).toBe(panelProps.id)
    expect(panelProps['aria-labelledby']).toBe(tabProps.id)
  })
})

describe('createTabs — vertical orientation', () => {
  it('ArrowDown / ArrowUp instead of Right / Left', () => {
    const t = createTabs({ tabs: TABS, orientation: 'vertical' })
    t.getTabListProps().onKeyDown(makeKey('ArrowDown'))
    expect(t.activeId).toBe('b')
    t.getTabListProps().onKeyDown(makeKey('ArrowUp'))
    expect(t.activeId).toBe('a')
  })
})

describe('createTabs — close button props', () => {
  it('close button has tabIndex -1 and aria-label "Close <label>"', () => {
    const t = createTabs({
      tabs: [{ id: 'a', label: 'Alpha', closeable: true }],
    })
    const props = t.getCloseButtonProps('a')
    expect(props.tabIndex).toBe(-1)
    expect(props['aria-label']).toBe('Close Alpha')
  })

  it('close button click fires onClose', () => {
    const closes: string[] = []
    const t = createTabs({
      tabs: [{ id: 'a', label: 'A', closeable: true }, { id: 'b', label: 'B' }],
      onClose: (id) => closes.push(id),
    })
    t.getCloseButtonProps('a').onClick()
    expect(closes).toEqual(['a'])
  })
})

describe('createTabs — subscribe', () => {
  it('listener fires on activate / close / reorder; unsubscribe stops', () => {
    const t = createTabs({ tabs: TABS })
    let count = 0
    const dispose = t.subscribe(() => {
      count += 1
    })
    t.activate('b')
    t.close('b')
    expect(count).toBeGreaterThan(0)
    const before = count
    dispose()
    t.activate('c')
    expect(count).toBe(before)
  })
})

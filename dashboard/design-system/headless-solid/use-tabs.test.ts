// @vitest-environment happy-dom
//
// Tests for headless-solid/use-tabs. Mirrors the Preact adapter
// scenarios using Solid's accessor + createRoot conventions.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createComputed, createRoot } from 'solid-js'
import type { TabDescriptor } from '../headless-core/tabs'
import { useTabs } from './use-tabs'

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

const tabsFixture: ReadonlyArray<TabDescriptor> = [
  { id: 't1', label: 'One' },
  { id: 't2', label: 'Two' },
  { id: 't3', label: 'Three' },
]

describe('useTabs', () => {
  it('exposes initial activeId from defaultActiveId', () => {
    const { activeId } = withRoot(() =>
      useTabs({ tabs: tabsFixture, defaultActiveId: 't2' }),
    )
    expect(activeId()).toBe('t2')
  })

  it('activate updates accessor', () => {
    const { activeId, activate } = withRoot(() => useTabs({ tabs: tabsFixture }))
    activate('t3')
    expect(activeId()).toBe('t3')
  })

  it('exposes tabs snapshot', () => {
    const { tabs } = withRoot(() => useTabs({ tabs: tabsFixture }))
    expect(tabs().map((t) => t.id)).toEqual(['t1', 't2', 't3'])
  })

  it('close removes a tab', () => {
    const { tabs, close } = withRoot(() => useTabs({ tabs: tabsFixture }))
    close('t2')
    expect(tabs().map((t) => t.id)).toEqual(['t1', 't3'])
  })

  it('getTabListProps returns role=tablist', () => {
    const { getTabListProps } = withRoot(() => useTabs({ tabs: tabsFixture }))
    expect(getTabListProps().role).toBe('tablist')
  })

  it('getTabProps returns role=tab with aria-selected', () => {
    const { getTabProps } = withRoot(() =>
      useTabs({ tabs: tabsFixture, defaultActiveId: 't1' }),
    )
    const props = getTabProps('t1')
    expect(props.role).toBe('tab')
    expect(props['aria-selected']).toBe(true)
  })

  it('createComputed re-runs on activate', () => {
    let runs = 0
    let last: string | null = null
    withRoot(() => {
      const { activeId, activate } = useTabs({
        tabs: tabsFixture,
        defaultActiveId: 't1',
      })
      createComputed(() => {
        last = activeId()
        runs += 1
      })
      activate('t2')
    })
    expect(runs).toBeGreaterThan(1)
    expect(last).toBe('t2')
  })

  it('reorder mutates tabs accessor', () => {
    const { tabs, reorder } = withRoot(() => useTabs({ tabs: tabsFixture }))
    reorder(['t3', 't1', 't2'])
    expect(tabs().map((t) => t.id)).toEqual(['t3', 't1', 't2'])
  })
})

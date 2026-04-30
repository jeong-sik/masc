// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot } from 'solid-js'
import type { ToolbarItem } from '../headless-core/toolbar'
import { useToolbar } from './use-toolbar'

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

const items: ReadonlyArray<ToolbarItem> = [
  { id: 'save', kind: 'button', label: 'Save' },
  { id: 'bold', kind: 'toggle', label: 'Bold', pressed: false },
  { id: 'sep', kind: 'separator' },
  { id: 'left', kind: 'radio', label: 'Left', checked: true, radioGroup: 'align' },
  { id: 'right', kind: 'radio', label: 'Right', checked: false, radioGroup: 'align' },
]

describe('useToolbar', () => {
  it('exposes visibleItems matching input length', () => {
    const { visibleItems, hasOverflow } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'Test' }),
    )
    expect(visibleItems().length).toBe(items.length)
    expect(hasOverflow()).toBe(false)
  })

  it('toggle flips aria-pressed', () => {
    const { toggle, getItemProps } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'Test' }),
    )
    toggle('bold')
    expect(getItemProps('bold')['aria-pressed']).toBe(true)
  })

  it('selectRadio enforces single-select within radio group', () => {
    const { selectRadio, getItemProps } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'Test' }),
    )
    selectRadio('right')
    expect(getItemProps('right')['aria-checked']).toBe(true)
    expect(getItemProps('left')['aria-checked']).toBe(false)
  })

  it('overflowAt narrows visibleItems', () => {
    const { visibleItems, overflowItems, hasOverflow } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'Test', overflowAt: 2 }),
    )
    expect(visibleItems().length).toBe(2)
    expect(overflowItems().length).toBeGreaterThan(0)
    expect(hasOverflow()).toBe(true)
  })

  it('openOverflowMenu flips overflowMenuOpen accessor', () => {
    const { overflowMenuOpen, openOverflowMenu, closeOverflowMenu } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'Test' }),
    )
    expect(overflowMenuOpen()).toBe(false)
    openOverflowMenu()
    expect(overflowMenuOpen()).toBe(true)
    closeOverflowMenu()
    expect(overflowMenuOpen()).toBe(false)
  })

  it('getRootProps returns role=toolbar with aria-label', () => {
    const { getRootProps } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'My Toolbar' }),
    )
    const props = getRootProps()
    expect(props.role).toBe('toolbar')
    expect(props['aria-label']).toBe('My Toolbar')
  })

  it('getOverflowMenuTriggerProps reflects accessor', () => {
    const { getOverflowMenuTriggerProps, openOverflowMenu } = withRoot(() =>
      useToolbar({ items, ariaLabel: 'Test' }),
    )
    const props = getOverflowMenuTriggerProps()
    expect(props['aria-haspopup']).toBe('menu')
    expect(props['aria-expanded']()).toBe(false)
    openOverflowMenu()
    expect(props['aria-expanded']()).toBe(true)
  })
})

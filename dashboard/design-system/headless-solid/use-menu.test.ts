// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot } from 'solid-js'
import type { MenuItemDescriptor } from '../headless-core/menu'
import { useMenu } from './use-menu'

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

const items: ReadonlyArray<MenuItemDescriptor> = [
  { id: 'open', kind: 'action', label: 'Open' },
  { id: 'save', kind: 'action', label: 'Save' },
  { id: 'sep', kind: 'separator' },
  { id: 'quit', kind: 'action', label: 'Quit' },
]

describe('useMenu', () => {
  it('starts closed', () => {
    const { isOpen } = withRoot(() => useMenu({ id: 'm1', items }))
    expect(isOpen()).toBe(false)
  })

  it('open() flips isOpen accessor', () => {
    const { isOpen, open } = withRoot(() => useMenu({ id: 'm1', items }))
    open()
    expect(isOpen()).toBe(true)
  })

  it('toggle() flips state both directions', () => {
    const { isOpen, toggle } = withRoot(() => useMenu({ id: 'm1', items }))
    toggle()
    expect(isOpen()).toBe(true)
    toggle()
    expect(isOpen()).toBe(false)
  })

  it('getTriggerProps reports aria-haspopup=menu', () => {
    const { getTriggerProps } = withRoot(() => useMenu({ id: 'm1', items }))
    expect(getTriggerProps()['aria-haspopup']).toBe('menu')
  })

  it('getMenuProps role=menu', () => {
    const { getMenuProps } = withRoot(() => useMenu({ id: 'm1', items }))
    expect(getMenuProps().role).toBe('menu')
  })

  it('select fires onSelect handler', () => {
    const calls: ReadonlyArray<string>[] = []
    const { open, select } = withRoot(() =>
      useMenu({
        id: 'm1',
        items,
        onSelect: (id, path) => calls.push([id, ...path]),
      }),
    )
    open()
    select('save')
    expect(calls.length).toBe(1)
    expect(calls[0]![0]).toBe('save')
  })

  it('triggerRef receives focus on close transition', () => {
    const trigger = document.createElement('button')
    document.body.append(trigger)
    const { open, close } = withRoot(() =>
      useMenu({ id: 'm1', items, triggerRef: () => trigger }),
    )
    open()
    close()
    expect(document.activeElement).toBe(trigger)
    trigger.remove()
  })
})

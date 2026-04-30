// @vitest-environment happy-dom
//
// Tests for headless-solid/use-tooltip. Covers initial state, show/hide
// transitions, prop bundle invariants, and createUniqueId fallback id.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createComputed, createRoot } from 'solid-js'
import { useTooltip } from './use-tooltip'

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

describe('useTooltip', () => {
  it('starts closed by default', () => {
    const { isOpen } = withRoot(() => useTooltip())
    expect(isOpen()).toBe(false)
  })

  it('show() opens, hide() closes — accessor reflects state', () => {
    const { isOpen, show, hide } = withRoot(() => useTooltip({ showDelay: 0, hideDelay: 0 }))
    show()
    expect(isOpen()).toBe(true)
    hide()
    expect(isOpen()).toBe(false)
  })

  it('aria-describedby accessor flips with isOpen', () => {
    const { triggerProps, show } = withRoot(() => useTooltip({ id: 'tip-x', showDelay: 0 }))
    expect(triggerProps['aria-describedby']()).toBeUndefined()
    show()
    expect(triggerProps['aria-describedby']()).toBe('tip-x')
  })

  it('contentProps id matches tooltip id', () => {
    const { contentProps, id } = withRoot(() => useTooltip({ id: 'tip-y' }))
    expect(contentProps.id).toBe('tip-y')
    expect(id).toBe('tip-y')
  })

  it('contentProps data-state reflects isOpen', () => {
    const { contentProps, show, hide } = withRoot(() =>
      useTooltip({ showDelay: 0, hideDelay: 0 }),
    )
    expect(contentProps['data-state']()).toBe('closed')
    show()
    expect(contentProps['data-state']()).toBe('open')
    hide()
    expect(contentProps['data-state']()).toBe('closed')
  })

  it('contentProps role=tooltip', () => {
    const { contentProps } = withRoot(() => useTooltip())
    expect(contentProps.role).toBe('tooltip')
  })

  it('placement defaults to top, accepts override', () => {
    const a = withRoot(() => useTooltip())
    expect(a.placement).toBe('top')
    dispose?.()
    dispose = undefined
    const b = withRoot(() => useTooltip({ placement: 'bottom' }))
    expect(b.placement).toBe('bottom')
    expect(b.contentProps['data-placement']).toBe('bottom')
  })

  it('createUniqueId fallback when no id supplied', () => {
    const a = withRoot(() => useTooltip())
    expect(a.id).toMatch(/^tip-/)
    expect(a.id.length).toBeGreaterThan(4)
  })

  it('createComputed re-runs on show()', () => {
    let runs = 0
    let last: boolean | undefined
    withRoot(() => {
      const { isOpen, show } = useTooltip({ showDelay: 0 })
      createComputed(() => {
        last = isOpen()
        runs += 1
      })
      show()
    })
    expect(runs).toBeGreaterThan(1)
    expect(last).toBe(true)
  })
})

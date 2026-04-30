// @vitest-environment happy-dom
//
// Tests for headless-solid/use-toasts. Mirrors Preact adapter scenarios
// adapted to Solid's accessor + createRoot conventions.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createComputed, createRoot } from 'solid-js'
import { createToastManager } from '../headless-core/toast-manager'
import {
  getRegionPauseHandlers,
  getToastItemProps,
  getToastRegionProps,
  useToasts,
} from './use-toasts'

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

describe('useToasts', () => {
  it('returns empty initial accessor', () => {
    const manager = createToastManager()
    const { toasts } = withRoot(() => useToasts(manager))
    expect(toasts()).toEqual([])
  })

  it('notify enqueues, accessor updates synchronously', () => {
    const manager = createToastManager()
    const { toasts, notify } = withRoot(() => useToasts(manager))
    const id = notify({ severity: 'info', message: 'Hello' })
    expect(toasts().length).toBe(1)
    expect(toasts()[0]!.id).toBe(id)
    expect(toasts()[0]!.message).toBe('Hello')
  })

  it('dismiss removes toast', () => {
    const manager = createToastManager()
    const { toasts, notify, dismiss } = withRoot(() => useToasts(manager))
    const id = notify({ severity: 'info', message: 'Hi' })
    expect(toasts().length).toBe(1)
    dismiss(id)
    expect(toasts().some((t) => t.state === 'dismissed' || t.id !== id)).toBeTruthy()
  })

  it('createComputed re-runs on signal update', () => {
    const manager = createToastManager()
    let runs = 0
    let lastLen = -1
    withRoot(() => {
      const { toasts } = useToasts(manager)
      createComputed(() => {
        lastLen = toasts().length
        runs += 1
      })
    })
    expect(runs).toBe(1)
    expect(lastLen).toBe(0)
    manager.notify({ severity: 'info', message: 'A' })
    expect(runs).toBe(2)
    expect(lastLen).toBe(1)
  })

  it('createRoot dispose unsubscribes', () => {
    const manager = createToastManager()
    let runs = 0
    const localDispose = createRoot((d) => {
      const { toasts } = useToasts(manager)
      createComputed(() => {
        void toasts()
        runs += 1
      })
      return d
    })
    expect(runs).toBe(1)
    manager.notify({ severity: 'info', message: 'A' })
    expect(runs).toBe(2)
    localDispose()
    manager.notify({ severity: 'info', message: 'B' })
    expect(runs).toBe(2)
  })
})

describe('getToastRegionProps', () => {
  it('returns frozen ARIA region attributes', () => {
    const props = getToastRegionProps()
    expect(props.role).toBe('region')
    expect(props['aria-label']).toBe('Notifications')
    expect(props['aria-live']).toBe('polite')
    expect(props['aria-atomic']).toBe('false')
    expect(Object.isFrozen(props)).toBe(true)
  })
})

describe('getToastItemProps', () => {
  it('maps severity to role + aria-live', () => {
    const manager = createToastManager()
    manager.notify({ severity: 'error', message: 'Boom' })
    const t = manager.getQueue()[0]!
    const props = getToastItemProps(t)
    expect(props.id).toBe(t.id)
    expect(props.role).toBe('alert')
    expect(props['aria-live']).toBe('assertive')
    expect(props['data-severity']).toBe('error')
  })

  it('info severity maps to status + polite', () => {
    const manager = createToastManager()
    manager.notify({ severity: 'info', message: 'FYI' })
    const t = manager.getQueue()[0]!
    const props = getToastItemProps(t)
    expect(props.role).toBe('status')
    expect(props['aria-live']).toBe('polite')
  })
})

describe('getRegionPauseHandlers', () => {
  it('mouse enter/leave triggers pauseAll/resumeAll', () => {
    const manager = createToastManager()
    let paused = 0
    let resumed = 0
    const wrapped: typeof manager = {
      ...manager,
      pauseAll: () => { paused += 1 },
      resumeAll: () => { resumed += 1 },
    }
    const handlers = getRegionPauseHandlers(wrapped)
    handlers.onMouseEnter()
    handlers.onMouseLeave()
    handlers.onFocusIn()
    handlers.onFocusOut()
    expect(paused).toBe(2)
    expect(resumed).toBe(2)
  })
})

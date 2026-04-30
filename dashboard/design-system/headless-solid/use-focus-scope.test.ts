// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot, createSignal } from 'solid-js'
import { useFocusScope } from './use-focus-scope'

let dispose: (() => void) | undefined
let container: HTMLElement

beforeEach(() => {
  dispose = undefined
  container = document.createElement('div')
  container.innerHTML = '<button id="a">A</button><button id="b">B</button>'
  document.body.append(container)
})

afterEach(() => {
  dispose?.()
  container.remove()
})

function withRoot<T>(fn: () => T): T {
  return createRoot((d) => {
    dispose = d
    return fn()
  })
}

describe('useFocusScope', () => {
  it('returns the underlying scope handle', () => {
    const { scope } = withRoot(() =>
      useFocusScope({ containerRef: () => container }),
    )
    expect(typeof scope.activate).toBe('function')
    expect(typeof scope.deactivate).toBe('function')
  })

  it('activates focus on mount when active=true (default)', () => {
    withRoot(() => useFocusScope({ containerRef: () => container }))
    const a = container.querySelector('#a') as HTMLButtonElement
    expect(document.activeElement).toBe(a)
  })

  it('does not activate when active=false', () => {
    const before = document.activeElement
    withRoot(() => useFocusScope({ containerRef: () => container, active: false }))
    expect(document.activeElement).toBe(before)
  })

  it('reactive active toggle activates and deactivates', () => {
    const [active, setActive] = createSignal(false)
    withRoot(() =>
      useFocusScope({ containerRef: () => container, active }),
    )
    const a = container.querySelector('#a') as HTMLButtonElement
    expect(document.activeElement).not.toBe(a)
    setActive(true)
    expect(document.activeElement).toBe(a)
    setActive(false)
    // After deactivate, focus is no longer trapped to a.
    expect(document.activeElement).not.toBe(a)
  })

  it('initialFocus function selects custom element', () => {
    withRoot(() =>
      useFocusScope({
        containerRef: () => container,
        initialFocus: () => container.querySelector('#b'),
      }),
    )
    const b = container.querySelector('#b') as HTMLButtonElement
    expect(document.activeElement).toBe(b)
  })

  it('createRoot dispose deactivates the scope', () => {
    const localDispose = createRoot((d) => {
      useFocusScope({ containerRef: () => container })
      return d
    })
    const a = container.querySelector('#a') as HTMLButtonElement
    expect(document.activeElement).toBe(a)
    localDispose()
    // After dispose, no longer trapping. Focus may move.
    expect(document.activeElement).not.toBe(null)
  })
})

// @ts-nocheck
// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { axe } from 'jest-axe'
import { createFocusScope } from './focus-scope'

describe('createFocusScope', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('collects tabbable elements', () => {
    container.innerHTML = `
      <a href="#">Link</a>
      <button>Btn</button>
      <input />
      <div tabindex="-1">Skip</div>
    `
    const scope = createFocusScope(container)
    expect(scope.first?.tagName).toBe('A')
    expect(scope.last?.tagName).toBe('INPUT')
  })

  it('focuses first element', () => {
    container.innerHTML = `<button id="a">A</button><button id="b">B</button>`
    const scope = createFocusScope(container)
    scope.focusFirst()
    expect(document.activeElement?.id).toBe('a')
  })

  it('cycles focus backward on Shift+Tab', () => {
    container.innerHTML = `<button id="a">A</button><button id="b">B</button>`
    const scope = createFocusScope(container)
    scope.first?.focus()

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Tab'
    ev.shiftKey = true
    scope.cycle(ev)

    expect(document.activeElement?.id).toBe('b')
  })

  it('cycles focus forward on Tab', () => {
    container.innerHTML = `<button id="a">A</button><button id="b">B</button>`
    const scope = createFocusScope(container)
    scope.last?.focus()

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Tab'
    ev.shiftKey = false
    scope.cycle(ev)

    expect(document.activeElement?.id).toBe('a')
  })

  it('ignores non-Tab keys', () => {
    container.innerHTML = `<button id="a">A</button>`
    const scope = createFocusScope(container)
    scope.first?.focus()

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Escape'
    scope.cycle(ev)

    expect(document.activeElement?.id).toBe('a')
    expect((ev as Event).defaultPrevented).toBe(false)
  })

  it('renders accessibly', async () => {
    container.innerHTML = `<button>A</button><button>B</button>`
    expect(await axe(container)).toHaveNoViolations()
  })
})

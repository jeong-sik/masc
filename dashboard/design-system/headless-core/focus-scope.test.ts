// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { createFocusScope } from './focus-scope'

describe('createFocusScope', () => {
  let container: HTMLElement
  let outsideButton: HTMLButtonElement

  beforeEach(() => {
    document.body.innerHTML = ''
    outsideButton = document.createElement('button')
    outsideButton.textContent = 'outside'
    outsideButton.id = 'outside'
    document.body.appendChild(outsideButton)

    container = document.createElement('div')
    container.id = 'scope'
    container.tabIndex = -1
    container.innerHTML = `
      <button id="b1">first</button>
      <input id="i1" />
      <a href="#" id="a1">link</a>
      <button id="b2" disabled>disabled</button>
      <button id="b3">last</button>
    `
    document.body.appendChild(container)
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('tabbables() collects focusable descendants in DOM order, skipping disabled', () => {
    const scope = createFocusScope({ containerRef: () => container })
    const ids = scope.tabbables().map((el) => el.id)
    expect(ids).toEqual(['b1', 'i1', 'a1', 'b3'])
  })

  it('tabbables() skips elements with tabindex="-1"', () => {
    container.querySelector('#i1')!.setAttribute('tabindex', '-1')
    const scope = createFocusScope({ containerRef: () => container })
    expect(scope.tabbables().map((el) => el.id)).toEqual(['b1', 'a1', 'b3'])
  })

  it('activate() with initialFocus="first" focuses the first tabbable', () => {
    const scope = createFocusScope({ containerRef: () => container })
    scope.activate()
    expect(document.activeElement?.id).toBe('b1')
  })

  it('activate() with initialFocus="container" focuses the container itself', () => {
    const scope = createFocusScope({
      containerRef: () => container,
      initialFocus: 'container',
    })
    scope.activate()
    expect(document.activeElement?.id).toBe('scope')
  })

  it('activate() with initialFocus function uses the returned element', () => {
    const scope = createFocusScope({
      containerRef: () => container,
      initialFocus: () => container.querySelector<HTMLElement>('#a1'),
    })
    scope.activate()
    expect(document.activeElement?.id).toBe('a1')
  })

  it('deactivate() restores focus to the element focused before activate()', () => {
    outsideButton.focus()
    expect(document.activeElement?.id).toBe('outside')
    const scope = createFocusScope({ containerRef: () => container })
    scope.activate()
    expect(document.activeElement?.id).toBe('b1')
    scope.deactivate()
    expect(document.activeElement?.id).toBe('outside')
  })

  it('deactivate() with restoreFocus=false leaves focus where it lands', () => {
    outsideButton.focus()
    const scope = createFocusScope({
      containerRef: () => container,
      restoreFocus: false,
    })
    scope.activate()
    expect(document.activeElement?.id).toBe('b1')
    scope.deactivate()
    expect(document.activeElement?.id).toBe('b1') // not restored
  })

  it('Tab on the last tabbable cycles to the first when loop=true (default)', () => {
    const scope = createFocusScope({ containerRef: () => container })
    scope.activate()
    scope.focusLast()
    expect(document.activeElement?.id).toBe('b3')
    container.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }),
    )
    expect(document.activeElement?.id).toBe('b1')
    scope.deactivate()
  })

  it('Shift+Tab on the first tabbable cycles to the last when loop=true', () => {
    const scope = createFocusScope({ containerRef: () => container })
    scope.activate()
    expect(document.activeElement?.id).toBe('b1')
    container.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true }),
    )
    expect(document.activeElement?.id).toBe('b3')
    scope.deactivate()
  })

  it('loop=false leaves Tab to the browser default (no preventDefault, no manual cycle)', () => {
    const scope = createFocusScope({
      containerRef: () => container,
      loop: false,
    })
    scope.activate()
    scope.focusLast()
    container.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }),
    )
    // Without loop, manual cycle is suppressed; happy-dom won't move focus
    // to the next tabbable on its own, so focus should remain on b3.
    expect(document.activeElement?.id).toBe('b3')
    scope.deactivate()
  })

  it('contains() reports descendant membership', () => {
    const scope = createFocusScope({ containerRef: () => container })
    expect(scope.contains(container.querySelector('#b1')!)).toBe(true)
    expect(scope.contains(outsideButton)).toBe(false)
  })

  it('activate() is idempotent (calling twice does not double-install handlers)', () => {
    const scope = createFocusScope({ containerRef: () => container })
    scope.activate()
    scope.activate() // no-op second time
    scope.deactivate()
    expect(document.activeElement).not.toBe(container.querySelector('#b1'))
  })

  it('deactivate() before activate() is a no-op', () => {
    const scope = createFocusScope({ containerRef: () => container })
    expect(() => scope.deactivate()).not.toThrow()
  })

  it('handles a container with zero tabbables: Tab pins focus on container', () => {
    const empty = document.createElement('div')
    empty.tabIndex = -1
    document.body.appendChild(empty)
    const scope = createFocusScope({
      containerRef: () => empty,
      initialFocus: 'container',
    })
    scope.activate()
    expect(document.activeElement).toBe(empty)
    empty.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }),
    )
    expect(document.activeElement).toBe(empty)
    scope.deactivate()
  })

  it('null container ref: activate() is a no-op', () => {
    const scope = createFocusScope({ containerRef: () => null })
    expect(() => scope.activate()).not.toThrow()
    // Nothing should be focused as a side-effect
    scope.deactivate()
  })
})

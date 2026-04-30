import { describe, expect, it } from 'vitest'
import { createFocusScope } from './focus-scope'

describe('createFocusScope', () => {
  it('returns undefined first/last when container is empty', () => {
    const container = document.createElement('div')
    const scope = createFocusScope(container)
    expect(scope.first).toBeUndefined()
    expect(scope.last).toBeUndefined()
  })

  it('finds first and last tabbable elements', () => {
    const container = document.createElement('div')
    container.innerHTML = '<button id="a">A</button><input id="b"><a href="#" id="c">C</a>'
    const scope = createFocusScope(container)
    expect(scope.first?.id).toBe('a')
    expect(scope.last?.id).toBe('c')
  })

  it('ignores elements with tabindex="-1"', () => {
    const container = document.createElement('div')
    container.innerHTML = '<button id="a">A</button><div tabindex="-1" id="b">B</div><button id="c">C</button>'
    const scope = createFocusScope(container)
    expect(scope.first?.id).toBe('a')
    expect(scope.last?.id).toBe('c')
  })

  it('cycles from first to last on Shift+Tab', () => {
    const container = document.createElement('div')
    container.innerHTML = '<button id="a">A</button><button id="b">B</button>'
    document.body.appendChild(container)
    const scope = createFocusScope(container)
    const btnA = container.querySelector('#a') as HTMLElement
    btnA.focus()
    const ev = new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true })
    scope.cycle(ev)
    expect(document.activeElement?.id).toBe('b')
    document.body.removeChild(container)
  })

  it('cycles from last to first on Tab', () => {
    const container = document.createElement('div')
    container.innerHTML = '<button id="a">A</button><button id="b">B</button>'
    document.body.appendChild(container)
    const scope = createFocusScope(container)
    const btnB = container.querySelector('#b') as HTMLElement
    btnB.focus()
    const ev = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true })
    scope.cycle(ev)
    expect(document.activeElement?.id).toBe('a')
    document.body.removeChild(container)
  })

  it('does nothing on non-Tab keys', () => {
    const container = document.createElement('div')
    container.innerHTML = '<button id="a">A</button>'
    document.body.appendChild(container)
    const scope = createFocusScope(container)
    const btnA = container.querySelector('#a') as HTMLElement
    btnA.focus()
    const ev = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
    scope.cycle(ev)
    expect(document.activeElement?.id).toBe('a')
    document.body.removeChild(container)
  })

  it('focuses first element via focusFirst', () => {
    const container = document.createElement('div')
    container.innerHTML = '<button id="a">A</button><button id="b">B</button>'
    document.body.appendChild(container)
    const scope = createFocusScope(container)
    scope.focusFirst()
    expect(document.activeElement?.id).toBe('a')
    document.body.removeChild(container)
  })
})

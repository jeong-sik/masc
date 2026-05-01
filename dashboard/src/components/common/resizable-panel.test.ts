// @ts-nocheck
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { ResizablePanel } from './resizable-panel'

const originalLocalStorage = window.localStorage
let store: Record<string, string> = {}

describe('ResizablePanel', () => {
  beforeEach(() => {
    store = {}
    Object.defineProperty(window, 'localStorage', {
      value: {
        getItem: (key: string) => store[key] ?? null,
        setItem: (key: string, value: string) => { store[key] = value },
        removeItem: (key: string) => { delete store[key] },
        clear: () => { store = {} },
        key: (index: number) => Object.keys(store)[index] ?? null,
        length: 0,
      },
      writable: true,
      configurable: true,
    })
    Object.defineProperty(window.localStorage, 'length', {
      get: () => Object.keys(store).length,
      configurable: true,
    })
  })

  afterEach(() => {
    Object.defineProperty(window, 'localStorage', {
      value: originalLocalStorage,
      writable: true,
      configurable: true,
    })
  })

  it('renders container', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: h('div', null, 'A'), second: h('div', null, 'B') }), container)
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
  })

  it('renders separator with role', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]')
    expect(sep).not.toBeNull()
  })

  it('renders aria-orientation horizontal by default', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('aria-orientation')).toBe('horizontal')
  })

  it('renders aria-orientation vertical when direction is vertical', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', direction: 'vertical', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('aria-orientation')).toBe('vertical')
  })

  it('renders aria-valuenow within range', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    const valuenow = Number(sep?.getAttribute('aria-valuenow'))
    expect(valuenow).toBeGreaterThanOrEqual(5)
    expect(valuenow).toBeLessThanOrEqual(95)
  })

  it('renders aria-valuemin and aria-valuemax', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('aria-valuemin')).toBe('5')
    expect(sep?.getAttribute('aria-valuemax')).toBe('95')
  })

  it('renders aria-label', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('aria-label')).toBe('패널 크기 조절')
  })

  it('is focusable', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('tabindex')).toBe('0')
  })

  it('reads ratio from localStorage', () => {
    store['masc-resizable:test'] = '0.7'
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('aria-valuenow')).toBe('70')
  })

  it('writes ratio to localStorage on keyboard nudge', async () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    const ev = new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })
    sep?.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(store['masc-resizable:test']).toBeDefined()
  })

  it('applies firstPanelClass and secondPanelClass', () => {
    const container = document.createElement('div')
    render(
      h(ResizablePanel, { storageKey: 'test', first: h('div', null, 'A'), second: h('div', null, 'B'), firstPanelClass: 'first-c', secondPanelClass: 'second-c' }),
      container,
    )
    expect(container.querySelector('.first-c')).not.toBeNull()
    expect(container.querySelector('.second-c')).not.toBeNull()
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null, class: 'panel-wrap' }), container)
    expect(container.querySelector('.panel-wrap')).not.toBeNull()
  })

  it('sets data-dragging on mousedown', async () => {
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('data-dragging')).toBe('false')
    sep?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(sep?.getAttribute('data-dragging')).toBe('true')
  })

  it('ignores invalid localStorage values', () => {
    store['masc-resizable:test'] = 'invalid'
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    const valuenow = Number(sep?.getAttribute('aria-valuenow'))
    expect(valuenow).toBeGreaterThanOrEqual(5)
    expect(valuenow).toBeLessThanOrEqual(95)
  })

  it('ignores out-of-range localStorage values', () => {
    store['masc-resizable:test'] = '2.0'
    const container = document.createElement('div')
    render(h(ResizablePanel, { storageKey: 'test', first: null, second: null }), container)
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep?.getAttribute('aria-valuenow')).not.toBe('200')
  })
})

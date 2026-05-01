import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { useRovingTabIndex } from './roving-tabindex'

function RovingUser({ itemCount, orientation }: { itemCount: number; orientation?: 'horizontal' | 'vertical' }) {
  const { activeIndex, handleKeyDown, getTabIndex } = useRovingTabIndex(itemCount, orientation)
  return h('div', {
    'data-active': activeIndex,
    onKeyDown: handleKeyDown,
  },
    Array.from({ length: itemCount }, (_, i) =>
      h('button', { 'data-index': i, 'data-tabindex': getTabIndex(i) }, `Item ${i}`)
    )
  )
}

describe('useRovingTabIndex', () => {
  it('starts at activeIndex 0', () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    expect(container.querySelector('div')?.getAttribute('data-active')).toBe('0')
  })

  it('ArrowRight increments activeIndex', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('1')
  })

  it('ArrowLeft decrements activeIndex', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('0')
  })

  it('ArrowDown increments when vertical', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3, orientation: 'vertical' }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('1')
  })

  it('ArrowUp decrements when vertical', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3, orientation: 'vertical' }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('0')
  })

  it('Home sets activeIndex to 0', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('0')
  })

  it('End sets activeIndex to last', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('2')
  })

  it('does not go below 0', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('0')
  })

  it('does not go above itemCount - 1', async () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 2 }), container)
    const div = container.querySelector('div') as HTMLElement
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    div.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(div.getAttribute('data-active')).toBe('1')
  })

  it('getTabIndex returns 0 for active and -1 for others', () => {
    const container = document.createElement('div')
    render(h(RovingUser, { itemCount: 3 }), container)
    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('data-tabindex')).toBe('0')
    expect(buttons[1]?.getAttribute('data-tabindex')).toBe('-1')
    expect(buttons[2]?.getAttribute('data-tabindex')).toBe('-1')
  })
})

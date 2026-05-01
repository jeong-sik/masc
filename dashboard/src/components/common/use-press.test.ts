// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { usePress } from './use-press'

function PressUser({ onPress }: { onPress?: () => void }) {
  const { pressed, pressProps } = usePress(onPress)
  return h('button', { 'data-pressed': pressed ? 'true' : undefined, ...pressProps }, 'Press')
}

describe('usePress', () => {
  it('returns pressed=false initially', () => {
    const container = document.createElement('div')
    render(h(PressUser, {}), container)
    const btn = container.querySelector('button')
    expect(btn?.getAttribute('data-pressed')).toBeNull()
  })

  it('sets pressed on pointerdown', async () => {
    const container = document.createElement('div')
    render(h(PressUser, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBe('true')
  })

  it('clears pressed on pointerup', async () => {
    const container = document.createElement('div')
    render(h(PressUser, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBeNull()
  })

  it('clears pressed on pointerleave', async () => {
    const container = document.createElement('div')
    render(h(PressUser, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBeNull()
  })

  it('calls onPress on pointerup', async () => {
    const onPress = vi.fn()
    const container = document.createElement('div')
    render(h(PressUser, { onPress }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onPress).toHaveBeenCalledOnce()
  })

  it('sets pressed on Enter keydown', async () => {
    const container = document.createElement('div')
    render(h(PressUser, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBe('true')
  })

  it('calls onPress on Enter keyup', async () => {
    const onPress = vi.fn()
    const container = document.createElement('div')
    render(h(PressUser, { onPress }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onPress).toHaveBeenCalledOnce()
  })

  it('sets pressed on Space keydown', async () => {
    const container = document.createElement('div')
    render(h(PressUser, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBe('true')
  })

  it('calls onPress on Space keyup', async () => {
    const onPress = vi.fn()
    const container = document.createElement('div')
    render(h(PressUser, { onPress }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new KeyboardEvent('keyup', { key: ' ', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onPress).toHaveBeenCalledOnce()
  })
})

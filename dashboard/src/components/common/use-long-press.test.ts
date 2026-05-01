// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { useLongPress } from './use-long-press'

function LongPressUser({ onLongPress }: { onLongPress?: () => void }) {
  const { longPressProps, pressing } = useLongPress({ onLongPress, threshold: 200 })
  return h('button', { ...longPressProps, 'data-pressing': pressing ? 'true' : undefined }, 'Hold')
}

describe('useLongPress', () => {
  it('calls onLongPress after threshold', () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const cb = vi.fn()
    const container = document.createElement('div')
    render(h(LongPressUser, { onLongPress: cb }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    vi.advanceTimersByTime(200)
    expect(cb).toHaveBeenCalledOnce()
    vi.useRealTimers()
  })

  it('does not call onLongPress if pointerup before threshold', () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const cb = vi.fn()
    const container = document.createElement('div')
    render(h(LongPressUser, { onLongPress: cb }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    vi.advanceTimersByTime(100)
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    vi.advanceTimersByTime(200)
    expect(cb).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('does not call onLongPress on non-primary button', () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const cb = vi.fn()
    const container = document.createElement('div')
    render(h(LongPressUser, { onLongPress: cb }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 1, bubbles: true }))
    vi.advanceTimersByTime(200)
    expect(cb).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('sets data-pressing while holding', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const container = document.createElement('div')
    render(h(LongPressUser, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressing')).toBe('true')
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressing')).toBeNull()
    vi.useRealTimers()
  })

  it('cancels on pointerleave', () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const cb = vi.fn()
    const container = document.createElement('div')
    render(h(LongPressUser, { onLongPress: cb }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true }))
    vi.advanceTimersByTime(200)
    expect(cb).not.toHaveBeenCalled()
    vi.useRealTimers()
  })
})

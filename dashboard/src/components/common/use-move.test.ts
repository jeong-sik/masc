// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h, type FunctionComponent } from 'preact'
import { render } from 'preact'
import { useMove } from './use-move'

type MoveOptions = NonNullable<Parameters<typeof useMove>[0]>

const MoveConsumer: FunctionComponent<MoveOptions> = ({ onMoveStart, onMove, onMoveEnd }) => {
  const { moving, moveProps } = useMove({ onMoveStart, onMove, onMoveEnd })
  return h('div', { 'data-testid': 'move-target', ...moveProps }, moving ? 'moving' : 'idle')
}

describe('useMove', () => {
  it('returns moving false initially', () => {
    const container = document.createElement('div')
    render(h(MoveConsumer), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    expect(el?.textContent).toBe('idle')
    expect(el?.getAttribute('data-moving')).toBeNull()
  })

  it('data-moving is undefined when not moving', () => {
    const container = document.createElement('div')
    render(h(MoveConsumer), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    expect(el?.getAttribute('data-moving')).toBeNull()
  })

  it('sets moving true on pointerdown with button 0', async () => {
    const container = document.createElement('div')
    render(h(MoveConsumer), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 10, clientY: 20 }))
    await new Promise((r) => setTimeout(r, 0))
    expect(el?.getAttribute('data-moving')).toBe('true')
    expect(el?.textContent).toBe('moving')
  })

  it('ignores pointerdown with non-zero button', async () => {
    const container = document.createElement('div')
    render(h(MoveConsumer), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 1, clientX: 10, clientY: 20 }))
    await new Promise((r) => setTimeout(r, 0))
    expect(el?.getAttribute('data-moving')).toBeNull()
    expect(el?.textContent).toBe('idle')
  })

  it('calls onMoveStart on pointerdown', () => {
    const onMoveStart = vi.fn()
    const container = document.createElement('div')
    render(h(MoveConsumer, { onMoveStart }), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 0, clientY: 0 }))
    expect(onMoveStart).toHaveBeenCalled()
  })

  it('calls onMove with delta on pointermove', () => {
    const onMove = vi.fn()
    const container = document.createElement('div')
    render(h(MoveConsumer, { onMove }), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 0, clientY: 0 }))
    window.dispatchEvent(new PointerEvent('pointermove', { clientX: 5, clientY: 10 }))
    expect(onMove).toHaveBeenCalledWith(5, 10)
  })

  it('calls onMoveEnd on pointerup', () => {
    const onMoveEnd = vi.fn()
    const container = document.createElement('div')
    render(h(MoveConsumer, { onMoveEnd }), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 0, clientY: 0 }))
    window.dispatchEvent(new PointerEvent('pointerup'))
    expect(onMoveEnd).toHaveBeenCalled()
  })

  it('resets moving to false after pointerup', async () => {
    const container = document.createElement('div')
    render(h(MoveConsumer), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 0, clientY: 0 }))
    await new Promise((r) => setTimeout(r, 0))
    expect(el?.getAttribute('data-moving')).toBe('true')
    window.dispatchEvent(new PointerEvent('pointerup'))
    await new Promise((r) => setTimeout(r, 0))
    expect(el?.getAttribute('data-moving')).toBeNull()
    expect(el?.textContent).toBe('idle')
  })

  it('accumulates delta across multiple pointermove events', () => {
    const onMove = vi.fn()
    const container = document.createElement('div')
    render(h(MoveConsumer, { onMove }), container)
    const el = container.querySelector('[data-testid="move-target"]') as HTMLElement
    el?.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 0, clientY: 0 }))
    window.dispatchEvent(new PointerEvent('pointermove', { clientX: 3, clientY: 4 }))
    window.dispatchEvent(new PointerEvent('pointermove', { clientX: 10, clientY: 20 }))
    expect(onMove).toHaveBeenCalledTimes(2)
    expect(onMove).toHaveBeenNthCalledWith(1, 3, 4)
    expect(onMove).toHaveBeenNthCalledWith(2, 7, 16)
  })
})

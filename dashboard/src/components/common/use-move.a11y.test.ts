// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { useMove } from './use-move'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function Movable({ onMoveStart, onMove, onMoveEnd }: {
  onMoveStart?: () => void
  onMove?: (dx: number, dy: number) => void
  onMoveEnd?: () => void
}) {
  const { moving, moveProps } = useMove({ onMoveStart, onMove, onMoveEnd })
  return html`<div ...${moveProps} data-moving=${moving ? 'true' : undefined}>Drag me</div>`
}

describe('useMove', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('sets moving on pointerdown', async () => {
    render(html`<${Movable} />`, container)
    const el = container.querySelector('div') as HTMLElement
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: 0, clientY: 0 }))
    await tick()
    expect(el.getAttribute('data-moving')).toBe('true')
  })

  it('calls onMove with deltas on pointermove', async () => {
    const onMove = vi.fn()
    render(html`<${Movable} onMove=${onMove} />`, container)
    const el = container.querySelector('div') as HTMLElement
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: 0, clientY: 0 }))
    await tick()
    window.dispatchEvent(new PointerEvent('pointermove', { clientX: 10, clientY: 5 }))
    await tick()
    expect(onMove).toHaveBeenCalledWith(10, 5)
  })

  it('calls onMoveStart and onMoveEnd', async () => {
    const onMoveStart = vi.fn()
    const onMoveEnd = vi.fn()
    render(html`<${Movable} onMoveStart=${onMoveStart} onMoveEnd=${onMoveEnd} />`, container)
    const el = container.querySelector('div') as HTMLElement
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: 0, clientY: 0 }))
    await tick()
    expect(onMoveStart).toHaveBeenCalled()
    window.dispatchEvent(new PointerEvent('pointerup', { clientX: 0, clientY: 0 }))
    await tick()
    expect(onMoveEnd).toHaveBeenCalled()
  })

  it('clears moving on pointerup', async () => {
    render(html`<${Movable} />`, container)
    const el = container.querySelector('div') as HTMLElement
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: 0, clientY: 0 }))
    await tick()
    expect(el.getAttribute('data-moving')).toBe('true')
    window.dispatchEvent(new PointerEvent('pointerup', { clientX: 0, clientY: 0 }))
    await tick()
    expect(el.getAttribute('data-moving')).toBeNull()
  })

  it('ignores non-primary button', async () => {
    render(html`<${Movable} />`, container)
    const el = container.querySelector('div') as HTMLElement
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 2 }))
    await tick()
    expect(el.getAttribute('data-moving')).toBeNull()
  })

  it('renders accessibly', async () => {
    render(html`<${Movable} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

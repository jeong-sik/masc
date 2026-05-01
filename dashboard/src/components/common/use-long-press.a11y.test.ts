// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { useLongPress } from './use-long-press'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

async function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
}

function Pressable({ onLongPress, threshold }: { onLongPress?: () => void; threshold?: number }) {
  const { pressing, longPressProps } = useLongPress({ onLongPress, threshold })
  return html`<button ...${longPressProps} data-pressing=${pressing ? 'true' : undefined}>Hold me</button>`
}

describe('useLongPress', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('sets pressing on pointerdown', async () => {
    render(html`<${Pressable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-pressing')).toBe('true')
  })

  it('calls onLongPress after threshold', async () => {
    const onLongPress = vi.fn()
    render(html`<${Pressable} onLongPress=${onLongPress} threshold=${100} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await sleep(150)
    expect(onLongPress).toHaveBeenCalled()
  })

  it('cancels on pointerup before threshold', async () => {
    const onLongPress = vi.fn()
    render(html`<${Pressable} onLongPress=${onLongPress} threshold=${200} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await tick()
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await sleep(250)
    expect(onLongPress).not.toHaveBeenCalled()
    expect(btn.getAttribute('data-pressing')).toBeNull()
  })

  it('cancels on pointerleave', async () => {
    const onLongPress = vi.fn()
    render(html`<${Pressable} onLongPress=${onLongPress} threshold=${200} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await tick()
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true }))
    await sleep(250)
    expect(onLongPress).not.toHaveBeenCalled()
    expect(btn.getAttribute('data-pressing')).toBeNull()
  })

  it('ignores non-primary button', async () => {
    render(html`<${Pressable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 2 }))
    await tick()
    expect(btn.getAttribute('data-pressing')).toBeNull()
  })

  it('renders accessibly', async () => {
    render(html`<${Pressable} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { usePress } from './use-press'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function Pressable({ onPress }: { onPress?: () => void }) {
  const { pressed, pressProps } = usePress(onPress)
  return html`<button ...${pressProps} data-pressed=${pressed ? 'true' : undefined}>Press me</button>`
}

describe('usePress', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('sets pressed on pointerdown', async () => {
    render(html`<${Pressable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-pressed')).toBe('true')
  })

  it('clears pressed on pointerup and calls onPress', async () => {
    const onPress = vi.fn()
    render(html`<${Pressable} onPress=${onPress} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-pressed')).toBeNull()
    expect(onPress).toHaveBeenCalled()
  })

  it('clears pressed on pointerleave without calling onPress', async () => {
    const onPress = vi.fn()
    render(html`<${Pressable} onPress=${onPress} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-pressed')).toBeNull()
    expect(onPress).not.toHaveBeenCalled()
  })

  it('calls onPress on Enter key', async () => {
    const onPress = vi.fn()
    render(html`<${Pressable} onPress=${onPress} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Enter'
    btn.dispatchEvent(ev)
    const up = new Event('keyup', { bubbles: true }) as any
    up.key = 'Enter'
    btn.dispatchEvent(up)
    await tick()
    expect(onPress).toHaveBeenCalled()
  })

  it('calls onPress on Space key', async () => {
    const onPress = vi.fn()
    render(html`<${Pressable} onPress=${onPress} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = ' '
    btn.dispatchEvent(ev)
    const up = new Event('keyup', { bubbles: true }) as any
    up.key = ' '
    btn.dispatchEvent(up)
    await tick()
    expect(onPress).toHaveBeenCalled()
  })

  it('ignores unrelated keys', async () => {
    const onPress = vi.fn()
    render(html`<${Pressable} onPress=${onPress} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Escape'
    btn.dispatchEvent(ev)
    await tick()
    expect(onPress).not.toHaveBeenCalled()
  })

  it('renders accessibly', async () => {
    render(html`<${Pressable} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

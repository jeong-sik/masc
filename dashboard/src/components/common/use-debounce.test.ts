// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useDebounce } from './use-debounce'

function tick(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
}

function DebounceTester({ fn, delay }: { fn: (v: string) => void; delay: number }) {
  const debounced = useDebounce(fn, delay)
  return html`
    <input
      onInput=${(e: InputEvent) => debounced((e.target as HTMLInputElement).value)}
    />
  `
}

describe('useDebounce', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('delays execution until pause', async () => {
    const fn = vi.fn()
    render(html`<${DebounceTester} fn=${fn} delay=${50} />`, container)
    const input = container.querySelector('input') as HTMLInputElement

    input.value = 'a'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    input.value = 'b'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    input.value = 'c'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))

    expect(fn).not.toHaveBeenCalled()
    await tick(60)
    expect(fn).toHaveBeenCalledTimes(1)
    expect(fn).toHaveBeenCalledWith('c')
  })

  it('resets timer on each call', async () => {
    const fn = vi.fn()
    render(html`<${DebounceTester} fn=${fn} delay=${50} />`, container)
    const input = container.querySelector('input') as HTMLInputElement

    input.value = 'first'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    await tick(30)
    input.value = 'second'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    await tick(30)

    expect(fn).not.toHaveBeenCalled()
    await tick(30)
    expect(fn).toHaveBeenCalledTimes(1)
    expect(fn).toHaveBeenCalledWith('second')
  })
})

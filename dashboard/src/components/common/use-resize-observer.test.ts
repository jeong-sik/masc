// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useResizeObserver } from './use-resize-observer'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function ResizeTester() {
  const { ref, size } = useResizeObserver()
  return html`
    <div ref=${ref} data-width=${size.width} data-height=${size.height} />
  `
}

describe('useResizeObserver', () => {
  let container: HTMLElement
  let callbacks: ResizeObserverCallback[] = []
  const OriginalResizeObserver = globalThis.ResizeObserver

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    callbacks = []

    globalThis.ResizeObserver = vi.fn(function (this: ResizeObserver, cb: ResizeObserverCallback) {
      callbacks.push(cb)
      return {
        observe: vi.fn(),
        disconnect: vi.fn(),
        unobserve: vi.fn(),
      } as unknown as ResizeObserver
    }) as unknown as typeof ResizeObserver
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    globalThis.ResizeObserver = OriginalResizeObserver
  })

  it('initializes with zero size', async () => {
    render(html`<${ResizeTester} />`, container)
    await tick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-width')).toBe('0')
    expect(el.getAttribute('data-height')).toBe('0')
  })

  it('updates size on resize observation', async () => {
    render(html`<${ResizeTester} />`, container)
    await tick()

    const entry = {
      contentRect: { width: 320, height: 240 },
    } as ResizeObserverEntry

    callbacks[0]?.([entry], new OriginalResizeObserver(() => {}))
    await tick()

    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-width')).toBe('320')
    expect(el.getAttribute('data-height')).toBe('240')
  })
})
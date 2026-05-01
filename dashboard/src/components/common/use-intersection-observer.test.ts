// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useIntersectionObserver } from './use-intersection-observer'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function IntersectionTester() {
  const { ref, isIntersecting } = useIntersectionObserver()
  return html`
    <div ref=${ref} data-intersecting=${isIntersecting ? 'true' : 'false'} />
  `
}

describe('useIntersectionObserver', () => {
  let container: HTMLElement
  let callbacks: IntersectionObserverCallback[] = []
  const OriginalIntersectionObserver = globalThis.IntersectionObserver

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    callbacks = []

    globalThis.IntersectionObserver = vi.fn(function (this: IntersectionObserver, cb: IntersectionObserverCallback) {
      callbacks.push(cb)
      return {
        observe: vi.fn(),
        disconnect: vi.fn(),
        unobserve: vi.fn(),
        takeRecords: vi.fn(),
        root: null,
        rootMargin: '',
        thresholds: [],
      } as unknown as IntersectionObserver
    }) as unknown as typeof IntersectionObserver
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    globalThis.IntersectionObserver = OriginalIntersectionObserver
  })

  it('initializes as not intersecting', async () => {
    render(html`<${IntersectionTester} />`, container)
    await tick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-intersecting')).toBe('false')
  })

  it('updates when intersection changes', async () => {
    render(html`<${IntersectionTester} />`, container)
    await tick()

    const entry = {
      isIntersecting: true,
      intersectionRatio: 0.5,
      boundingClientRect: {} as DOMRectReadOnly,
      intersectionRect: {} as DOMRectReadOnly,
      rootBounds: null,
      target: document.createElement('div'),
      time: Date.now(),
    } as IntersectionObserverEntry

    callbacks[0]?.([entry], new OriginalIntersectionObserver(() => {}))
    await tick()

    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-intersecting')).toBe('true')
  })
})

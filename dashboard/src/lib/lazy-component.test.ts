import { html } from 'htm/preact'
import { Component, render, type ComponentChildren } from 'preact'
import { Suspense } from 'preact/compat'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPreloadableLazy } from './lazy-component'

class TestErrorBoundary extends Component<
  { children: ComponentChildren; onError?: (err: Error) => void },
  { error: Error | null }
> {
  override state = { error: null as Error | null }
  static getDerivedStateFromError(error: Error) {
    return { error }
  }
  override componentDidCatch(error: Error) {
    this.props.onError?.(error)
  }
  override render() {
    if (this.state.error) {
      return html`<div data-testid="err">${this.state.error.message}</div>`
    }
    return this.props.children
  }
}

async function flush(rounds = 4): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

describe('createPreloadableLazy', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('suspends on cold render until loader resolves, then mounts synchronously', async () => {
    let resolveLoader!: (comp: (props: { label: string }) => unknown) => void
    const loader = vi.fn(
      () => new Promise<(props: { label: string }) => unknown>((r) => { resolveLoader = r }),
    )
    const Lazy = createPreloadableLazy<{ label: string }>(loader as never)

    render(
      html`<${Suspense} fallback=${html`<span data-testid="fb">loading</span>`}><${Lazy.Component} label="hello" /><//>`,
      container,
    )
    await flush(1)
    expect(container.querySelector('[data-testid="fb"]')?.textContent).toBe('loading')
    expect(loader).toHaveBeenCalledTimes(1)

    resolveLoader(({ label }) => html`<div data-testid="loaded">${label}</div>`)
    await flush()
    expect(container.querySelector('[data-testid="loaded"]')?.textContent).toBe('hello')
  })

  it('renders synchronously with zero fallback after preload resolves', async () => {
    const loader = vi.fn(async () => ({ label }: { label: string }) => html`<div data-testid="sync">${label}</div>`)
    const Lazy = createPreloadableLazy<{ label: string }>(loader as never)

    await Lazy.preload()
    render(
      html`<${Suspense} fallback=${html`<span data-testid="fb">loading</span>`}><${Lazy.Component} label="instant" /><//>`,
      container,
    )
    expect(container.querySelector('[data-testid="fb"]')).toBeNull()
    expect(container.querySelector('[data-testid="sync"]')?.textContent).toBe('instant')
    expect(loader).toHaveBeenCalledTimes(1)
  })

  it('does not poison mounted render when a background preload fails transiently', async () => {
    let attempt = 0
    const loader = vi.fn(async () => {
      attempt += 1
      if (attempt === 1) throw new Error('offline hover')
      return ({ label }: { label: string }) => html`<div data-testid="ok">${label}</div>`
    })
    const Lazy = createPreloadableLazy<{ label: string }>(loader as never)

    await expect(Lazy.preload()).rejects.toThrow('offline hover')

    render(
      html`<${TestErrorBoundary}><${Suspense} fallback=${null}><${Lazy.Component} label="recovered" /><//><//>`,
      container,
    )
    await flush()
    expect(container.querySelector('[data-testid="err"]')).toBeNull()
    expect(container.querySelector('[data-testid="ok"]')?.textContent).toBe('recovered')
    expect(loader).toHaveBeenCalledTimes(2)
  })

  it('propagates mounted render failure to ErrorBoundary and allows subsequent retry', async () => {
    let attempt = 0
    const loader = vi.fn(async () => {
      attempt += 1
      if (attempt === 1) throw new Error('chunk missing')
      return ({ label }: { label: string }) => html`<div data-testid="retry-ok">${label}</div>`
    })
    const Lazy = createPreloadableLazy<{ label: string }>(loader as never)

    render(
      html`<${TestErrorBoundary}><${Suspense} fallback=${null}><${Lazy.Component} label="first" /><//><//>`,
      container,
    )
    await flush()
    expect(container.querySelector('[data-testid="err"]')?.textContent).toBe('chunk missing')

    render(null, container)
    render(
      html`<${TestErrorBoundary}><${Suspense} fallback=${null}><${Lazy.Component} label="second" /><//><//>`,
      container,
    )
    await flush()
    expect(container.querySelector('[data-testid="retry-ok"]')?.textContent).toBe('second')
    expect(loader).toHaveBeenCalledTimes(2)
  })
})

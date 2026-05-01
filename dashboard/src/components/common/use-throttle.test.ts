// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useThrottle } from './use-throttle'

function tick(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
}

function ThrottleTester({ fn, interval }: { fn: (v: string) => void; interval: number }) {
  const throttled = useThrottle(fn, interval)
  return html`
    <button
      onClick=${() => throttled('clicked')}
    />
  `
}

describe('useThrottle', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('executes immediately on first call', () => {
    const fn = vi.fn()
    render(html`<${ThrottleTester} fn=${fn} interval=${100} />`, container)
    const btn = container.querySelector('button') as HTMLButtonElement

    btn.click()
    expect(fn).toHaveBeenCalledTimes(1)
    expect(fn).toHaveBeenCalledWith('clicked')
  })

  it('skips calls within interval', () => {
    const fn = vi.fn()
    render(html`<${ThrottleTester} fn=${fn} interval=${100} />`, container)
    const btn = container.querySelector('button') as HTMLButtonElement

    btn.click()
    btn.click()
    btn.click()

    expect(fn).toHaveBeenCalledTimes(1)
  })

  it('executes trailing call after interval', async () => {
    const fn = vi.fn()
    render(html`<${ThrottleTester} fn=${fn} interval=${50} />`, container)
    const btn = container.querySelector('button') as HTMLButtonElement

    btn.click()
    btn.click()

    expect(fn).toHaveBeenCalledTimes(1)
    await tick(60)
    expect(fn).toHaveBeenCalledTimes(2)
    expect(fn).toHaveBeenLastCalledWith('clicked')
  })
})

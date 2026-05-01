// @ts-nocheck
// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useRovingTabIndex } from './roving-tabindex'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function RovingTester({ itemCount = 3 }: { itemCount?: number }) {
  const { activeIndex, handleKeyDown, getTabIndex } = useRovingTabIndex(itemCount)
  return html`
    <div onKeyDown=${handleKeyDown} data-testid="container">
      ${Array.from({ length: itemCount }).map((_, i) => html`
        <div key=${i} data-index=${i} data-active=${i === activeIndex ? 'true' : 'false'} data-tabindex=${getTabIndex(i)} data-testid="item" />
      `)}
    </div>
  `
}

describe('useRovingTabIndex', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('starts with first item active', async () => {
    render(html`<${RovingTester} />`, container)
    await tick()
    const items = container.querySelectorAll('[data-testid="item"]')
    expect(items[0].getAttribute('data-active')).toBe('true')
    expect(items[1].getAttribute('data-active')).toBe('false')
  })

  it('moves right with ArrowRight', async () => {
    render(html`<${RovingTester} />`, container)
    await tick()
    const el = container.querySelector('[data-testid="container"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    el.dispatchEvent(ev)
    await tick()
    const items = container.querySelectorAll('[data-testid="item"]')
    expect(items[1].getAttribute('data-active')).toBe('true')
  })

  it('moves left with ArrowLeft', async () => {
    render(html`<${RovingTester} />`, container)
    await tick()
    const el = container.querySelector('[data-testid="container"]') as HTMLElement
    const right = new Event('keydown', { bubbles: true }) as any
    right.key = 'ArrowRight'
    el.dispatchEvent(right)
    await tick()
    const left = new Event('keydown', { bubbles: true }) as any
    left.key = 'ArrowLeft'
    el.dispatchEvent(left)
    await tick()
    const items = container.querySelectorAll('[data-testid="item"]')
    expect(items[0].getAttribute('data-active')).toBe('true')
  })

  it('jumps to first with Home', async () => {
    render(html`<${RovingTester} />`, container)
    await tick()
    const el = container.querySelector('[data-testid="container"]') as HTMLElement
    const right = new Event('keydown', { bubbles: true }) as any
    right.key = 'ArrowRight'
    el.dispatchEvent(right)
    await tick()
    const home = new Event('keydown', { bubbles: true }) as any
    home.key = 'Home'
    el.dispatchEvent(home)
    await tick()
    const items = container.querySelectorAll('[data-testid="item"]')
    expect(items[0].getAttribute('data-active')).toBe('true')
  })

  it('jumps to last with End', async () => {
    render(html`<${RovingTester} />`, container)
    await tick()
    const el = container.querySelector('[data-testid="container"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'End'
    el.dispatchEvent(ev)
    await tick()
    const items = container.querySelectorAll('[data-testid="item"]')
    expect(items[2].getAttribute('data-active')).toBe('true')
  })

  it('returns tabindex 0 for active and -1 for inactive', async () => {
    render(html`<${RovingTester} />`, container)
    await tick()
    const items = container.querySelectorAll('[data-testid="item"]')
    expect(items[0].getAttribute('data-tabindex')).toBe('0')
    expect(items[1].getAttribute('data-tabindex')).toBe('-1')
  })
})

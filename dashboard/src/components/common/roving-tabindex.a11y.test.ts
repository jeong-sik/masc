// @ts-nocheck
// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { useRovingTabIndex } from './roving-tabindex'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
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

  function Toolbar({
    itemCount,
    orientation,
  }: {
    itemCount: number
    orientation?: 'horizontal' | 'vertical'
  }) {
    const { activeIndex, handleKeyDown, getTabIndex } = useRovingTabIndex(
      itemCount,
      orientation,
    )
    return html`
      <div onKeyDown=${handleKeyDown} role="toolbar">
        ${Array.from({ length: itemCount }, (_, i) =>
          html`<button key=${i} tabIndex=${getTabIndex(i)} data-index=${i}>
            Item ${i}
          </button>`,
        )}
      </div>
    `
  }

  it('sets first item tabbable by default', () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('tabindex')).toBe('0')
    expect(buttons[1]?.getAttribute('tabindex')).toBe('-1')
    expect(buttons[2]?.getAttribute('tabindex')).toBe('-1')
  })

  it('moves focus forward on ArrowRight', async () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('tabindex')).toBe('-1')
    expect(buttons[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('moves focus backward on ArrowLeft', async () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    // move to index 1
    let ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    div.dispatchEvent(ev)
    await tick()

    // move back to index 0
    ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowLeft'
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('tabindex')).toBe('0')
    expect(buttons[1]?.getAttribute('tabindex')).toBe('-1')
  })

  it('respects boundaries (no wrap)', async () => {
    render(html`<${Toolbar} itemCount=${2} />`, container)
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    // try moving past last item
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    div.dispatchEvent(ev)
    await tick()
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('jumps to first on Home', async () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    // move to last
    let ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    div.dispatchEvent(ev)
    await tick()
    div.dispatchEvent(ev)
    await tick()

    // home
    ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Home'
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('tabindex')).toBe('0')
  })

  it('jumps to last on End', async () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'End'
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[2]?.getAttribute('tabindex')).toBe('0')
  })

  it('uses vertical arrows when orientation=vertical', async () => {
    render(
      html`<${Toolbar} itemCount=${3} orientation="vertical" />`,
      container,
    )
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowDown'
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('ignores unrelated keys', async () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    const div = container.querySelector('[role="toolbar"]') as HTMLElement

    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Escape'
    div.dispatchEvent(ev)
    await tick()

    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('tabindex')).toBe('0')
  })

  it('renders accessibly', async () => {
    render(html`<${Toolbar} itemCount=${3} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
